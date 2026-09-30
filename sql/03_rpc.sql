-- 03_rpc.sql : all business rules live here (security definer). Safe to re-run.

-- ---------- internal helpers (not callable by API roles) ----------
create or replace function public._rand_token() returns text
language sql volatile set search_path = public, extensions, pg_temp as $$
  select translate(encode(gen_random_bytes(18), 'base64'), '+/', 'ab');   -- 24 chars
$$;

create or replace function public._new_ticket_code() returns text
language plpgsql volatile set search_path = public, extensions, pg_temp as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- no 0/O/1/I
  b bytea; c text; i int;
begin
  loop
    b := gen_random_bytes(10); c := 'TKT-';
    for i in 0..9 loop
      c := c || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.tickets where code = c);
  end loop;
  return c;
end $$;

create or replace function public._seats_taken(p_type_id bigint) returns int
language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(qty), 0)::int from public.orders
  where type_id = p_type_id and status in ('pending','approved');
$$;

revoke all on function public._rand_token()        from public, anon, authenticated;
revoke all on function public._new_ticket_code()   from public, anon, authenticated;
revoke all on function public._seats_taken(bigint) from public, anon, authenticated;

-- ---------- public: ticket types with seats left ----------
create or replace function public.public_ticket_types()
returns table (id bigint, name text, description text, price int, capacity int,
               payment_qr_path text, accent_color text, sort_order int, remaining int)
language sql stable security definer set search_path = public, pg_temp as $$
  select t.id, t.name, t.description, t.price, t.capacity, t.payment_qr_path, t.accent_color,
         t.sort_order, greatest(t.capacity - public._seats_taken(t.id), 0)
  from public.ticket_types t
  where t.active
  order by t.sort_order, t.id;
$$;
revoke all on function public.public_ticket_types() from public, anon, authenticated;
grant execute on function public.public_ticket_types() to anon, authenticated;

-- ---------- public: create_order ----------
-- Price comes from ticket_types, never the client. Errors are plain codes the page maps to messages.
create or replace function public.create_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_payer_name text, p_screenshot_path text, p_names text[]
) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  s   public.event_settings%rowtype;
  t   public.ticket_types%rowtype;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name  text := btrim(coalesce(p_buyer_name, ''));
  v_payer text := btrim(coalesce(p_payer_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_order public.orders%rowtype;
  v_left  int; i int; nm text;
begin
  select * into s from public.event_settings where id = 1;
  if not found or not s.sales_open
     or (s.sales_start is not null and now() < s.sales_start)
     or (s.sales_end   is not null and now() > s.sales_end) then
    raise exception 'SALES_CLOSED';
  end if;

  if p_qty is null or p_qty < 1 then raise exception 'BAD_QTY'; end if;
  if p_qty > s.max_per_order then raise exception 'MAX_PER_ORDER:%', s.max_per_order; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'BAD_NAME'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 10 or length(v_phone) > 20 then raise exception 'BAD_PHONE'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'BAD_EMAIL'; end if;
  if length(v_payer) < 2 or length(v_payer) > 80 then raise exception 'BAD_PAYER'; end if;
  if p_names is null or coalesce(array_length(p_names, 1), 0) <> p_qty then raise exception 'BAD_ATTENDEES'; end if;
  foreach nm in array p_names loop
    if length(btrim(coalesce(nm, ''))) < 2 or length(nm) > 80 then raise exception 'BAD_ATTENDEES'; end if;
  end loop;

  -- screenshot must be a path uploaded through the public uploader and not used by another order
  if p_screenshot_path is null or p_screenshot_path !~ '^[0-9a-f-]{36}\.jpg$'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'screenshots' and o.name = p_screenshot_path)
     or exists (select 1 from public.orders where screenshot_path = p_screenshot_path) then
    raise exception 'BAD_SCREENSHOT';
  end if;

  -- Lock the ticket type row: concurrent buyers of this type queue here, so seats cannot be oversold.
  select * into t from public.ticket_types where id = p_type_id and active for update;
  if not found then raise exception 'TYPE_UNAVAILABLE'; end if;

  v_left := t.capacity - public._seats_taken(t.id);
  if v_left <= 0 then raise exception 'SOLD_OUT'; end if;
  if p_qty > v_left then raise exception 'NOT_ENOUGH_SEATS:%', v_left; end if;

  if (select count(*) from public.orders where lower(email) = v_email and status = 'pending') >= 3 then
    raise exception 'TOO_MANY_PENDING';
  end if;

  insert into public.orders (order_no, token, type_id, type_name, unit_price, qty, amount,
                             buyer_name, email, phone, payer_name, screenshot_path, status, source)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), t.id, t.name, t.price, p_qty,
          t.price * p_qty, v_name, v_email, v_phone, v_payer, p_screenshot_path, 'pending', 'online')
  returning * into v_order;

  for i in 1..p_qty loop
    insert into public.tickets (order_id, code, attendee_name)
    values (v_order.id, public._new_ticket_code(), btrim(p_names[i]));
  end loop;

  return v_order.token;
end $$;
revoke all on function public.create_order(bigint,int,text,text,text,text,text,text[]) from public, anon, authenticated;
grant execute on function public.create_order(bigint,int,text,text,text,text,text,text[]) to anon, authenticated;

-- ---------- public: get_order (by unguessable token) ----------
create or replace function public.get_order(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; tk jsonb := '[]'::jsonb;
begin
  if p_token is null or length(p_token) <> 24 then return null; end if;
  select * into o from public.orders where token = p_token;
  if not found then return null; end if;
  if o.status = 'approved' then
    select coalesce(jsonb_agg(jsonb_build_object('code', code, 'attendee_name', attendee_name) order by id), '[]'::jsonb)
      into tk from public.tickets where order_id = o.id;
  end if;
  return jsonb_build_object(
    'order_no', o.order_no, 'status', o.status, 'reject_reason', o.reject_reason,
    'type_id', o.type_id, 'type_name', o.type_name, 'qty', o.qty, 'amount', o.amount,
    'buyer_name', o.buyer_name, 'email', o.email, 'created_at', o.created_at,
    'accent_color', (select accent_color from public.ticket_types where id = o.type_id),
    'tickets', tk);
end $$;
revoke all on function public.get_order(text) from public, anon, authenticated;
grant execute on function public.get_order(text) to anon, authenticated;

-- ---------- admin: change order status ----------
-- pending -> approved | rejected ; rejected -> pending | approved (seat check) ; approved -> rejected
create or replace function public.admin_set_order_status(p_order_id bigint, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; t public.ticket_types%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'BAD_STATUS'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status = p_status then return to_jsonb(o) - 'screenshot_path'; end if;

  if not ((o.status = 'pending'  and p_status in ('approved','rejected'))
       or (o.status = 'rejected' and p_status in ('pending','approved'))
       or (o.status = 'approved' and p_status = 'rejected')) then
    raise exception 'BAD_TRANSITION:% -> %', o.status, p_status;
  end if;

  if o.status = 'rejected' then      -- seats were released on rejection: take them again, if still free
    select * into t from public.ticket_types where id = o.type_id for update;
    if o.qty > t.capacity - public._seats_taken(t.id) then raise exception 'NO_SEATS_LEFT'; end if;
  end if;

  update public.orders set
    status = p_status,
    reject_reason = case when p_status = 'rejected' then nullif(btrim(coalesce(p_reason, '')), '') else null end,
    approved_at   = case when p_status = 'approved' then now() else null end
  where id = o.id returning * into o;
  return to_jsonb(o) - 'screenshot_path';
end $$;
revoke all on function public.admin_set_order_status(bigint,text,text) from public, anon, authenticated;
grant execute on function public.admin_set_order_status(bigint,text,text) to authenticated;

-- ---------- admin: manual order (cash / complimentary). Issued as approved. ----------
create or replace function public.admin_create_manual_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_names text[], p_amount int default null
) returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare t public.ticket_types%rowtype; o public.orders%rowtype; i int; nm text;
        v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 50 then raise exception 'BAD_QTY'; end if;
  if length(btrim(coalesce(p_buyer_name, ''))) < 2 then raise exception 'BAD_NAME'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if p_names is null or coalesce(array_length(p_names, 1), 0) <> p_qty then raise exception 'BAD_ATTENDEES'; end if;
  foreach nm in array p_names loop
    if length(btrim(coalesce(nm, ''))) < 2 then raise exception 'BAD_ATTENDEES'; end if;
  end loop;
  if p_amount is not null and p_amount < 0 then raise exception 'BAD_AMOUNT'; end if;

  select * into t from public.ticket_types where id = p_type_id for update;
  if not found then raise exception 'TYPE_UNAVAILABLE'; end if;
  if p_qty > t.capacity - public._seats_taken(t.id) then
    raise exception 'NOT_ENOUGH_SEATS:%', greatest(t.capacity - public._seats_taken(t.id), 0);
  end if;

  insert into public.orders (order_no, token, type_id, type_name, unit_price, qty, amount, buyer_name, email,
                             phone, payer_name, status, source, approved_at)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), t.id, t.name, t.price, p_qty,
          coalesce(p_amount, t.price * p_qty), btrim(p_buyer_name), v_email, btrim(coalesce(p_phone, '')),
          'manual', 'approved', 'manual', now())
  returning * into o;
  for i in 1..p_qty loop
    insert into public.tickets (order_id, code, attendee_name)
    values (o.id, public._new_ticket_code(), btrim(p_names[i]));
  end loop;
  return jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'token', o.token);
end $$;
revoke all on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int) from public, anon, authenticated;
grant execute on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int) to authenticated;

-- ---------- admin: read email templates (column is not directly readable) ----------
create or replace function public.admin_get_email_templates() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return (select email_templates from public.event_settings where id = 1);
end $$;
revoke all on function public.admin_get_email_templates() from public, anon, authenticated;
grant execute on function public.admin_get_email_templates() to authenticated;

-- ---------- admin: seats taken per type (for the Ticket types tab) ----------
create or replace function public.admin_type_counts() returns table (type_id bigint, taken int, approved int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  return query
    select t.id, public._seats_taken(t.id),
           coalesce((select sum(o.qty)::int from public.orders o where o.type_id = t.id and o.status = 'approved'), 0)
    from public.ticket_types t;
end $$;
revoke all on function public.admin_type_counts() from public, anon, authenticated;
grant execute on function public.admin_type_counts() to authenticated;

-- ---------- scanner: check_in / undo / stats / recent ----------
create or replace function public.check_in(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_who  text := coalesce(auth.jwt() ->> 'email', 'unknown');
  tk public.tickets%rowtype; o public.orders%rowtype; r jsonb;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into tk from public.tickets where code = v_code;
  if not found then
    insert into public.scan_log (code, result, scanned_by) values (left(v_code, 40), 'invalid', v_who);
    return jsonb_build_object('result', 'invalid');
  end if;
  select * into o from public.orders where id = tk.order_id;
  if o.status <> 'approved' then
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'not_valid', v_who);
    return jsonb_build_object('result', 'not_valid', 'attendee_name', tk.attendee_name, 'type_name', o.type_name);
  end if;

  update public.tickets set used = true, used_at = now(), used_by = v_who
   where id = tk.id and used = false
   returning * into tk;
  if found then
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'ok', v_who);
    return jsonb_build_object('result', 'ok', 'attendee_name', tk.attendee_name, 'type_name', o.type_name,
                              'code', v_code, 'used_at', tk.used_at);
  end if;
  select * into tk from public.tickets where code = v_code;
  insert into public.scan_log (code, result, scanned_by) values (v_code, 'already_used', v_who);
  return jsonb_build_object('result', 'already_used', 'attendee_name', tk.attendee_name, 'type_name', o.type_name,
                            'code', v_code, 'used_at', tk.used_at);
end $$;
revoke all on function public.check_in(text) from public, anon, authenticated;
grant execute on function public.check_in(text) to authenticated;

-- Undo the calling user's most recent successful check-in.
create or replace function public.undo_check_in() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_who text := coalesce(auth.jwt() ->> 'email', 'unknown'); l public.scan_log%rowtype; tk public.tickets%rowtype;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into l from public.scan_log
   where result = 'ok' and undone = false and scanned_by = v_who
   order by id desc limit 1 for update;
  if not found then return jsonb_build_object('result', 'nothing_to_undo'); end if;
  update public.tickets set used = false, used_at = null, used_by = null
   where code = l.code and used = true returning * into tk;
  update public.scan_log set undone = true where id = l.id;
  insert into public.scan_log (code, result, scanned_by) values (l.code, 'undone', v_who);
  return jsonb_build_object('result', 'undone', 'code', l.code, 'attendee_name', tk.attendee_name);
end $$;
revoke all on function public.undo_check_in() from public, anon, authenticated;
grant execute on function public.undo_check_in() to authenticated;

create or replace function public.scan_stats() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  return (select jsonb_build_object(
            'checked_in', count(*) filter (where t.used),
            'total', count(*))
          from public.tickets t join public.orders o on o.id = t.order_id
          where o.status = 'approved');
end $$;
revoke all on function public.scan_stats() from public, anon, authenticated;
grant execute on function public.scan_stats() to authenticated;

create or replace function public.recent_scans(p_limit int default 20)
returns table (code text, result text, attendee_name text, type_name text, created_at timestamptz, undone boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  return query
    select l.code, l.result, t.attendee_name, o.type_name, l.created_at, l.undone
    from public.scan_log l
    left join public.tickets t on t.code = l.code
    left join public.orders  o on o.id = t.order_id
    order by l.id desc limit least(greatest(coalesce(p_limit, 20), 1), 100);
end $$;
revoke all on function public.recent_scans(int) from public, anon, authenticated;
grant execute on function public.recent_scans(int) to authenticated;
