-- 08_upgrade_v2.sql : ONE file to upgrade an existing setup (paste & run once in the Supabase SQL editor).
-- Adds: one QR per order (admits the whole group), Aadhaar photo per person, instructions panel.
-- Safe to re-run. Existing orders are converted; QR codes already emailed keep working.

-- 1) new columns + convert existing orders
alter table public.event_settings add column if not exists instructions_text text not null default '';
alter table public.orders  add column if not exists ticket_code   text;
alter table public.orders  add column if not exists checked_in    boolean not null default false;
alter table public.orders  add column if not exists checked_in_at timestamptz;
alter table public.orders  add column if not exists checked_in_by text;
create unique index if not exists orders_ticket_code_key on public.orders (ticket_code);
alter table public.tickets add column if not exists id_path text;        -- Aadhaar image, private bucket "ids"
alter table public.tickets alter column code drop not null;              -- per-person codes are no longer used

-- carry over orders made before v2: the first person's code becomes the order's QR code,
-- and an order counts as checked in if any of its people were already scanned
update public.orders o
   set ticket_code = (select t.code from public.tickets t where t.order_id = o.id and t.code is not null order by t.id limit 1)
 where o.ticket_code is null;
update public.orders o
   set checked_in = true,
       checked_in_at = (select max(t.used_at) from public.tickets t where t.order_id = o.id and t.used)
 where not o.checked_in and exists (select 1 from public.tickets t where t.order_id = o.id and t.used);
update public.tickets t
   set used = true, used_at = coalesce(t.used_at, o.checked_in_at), used_by = coalesce(t.used_by, o.checked_in_by)
  from public.orders o
 where o.id = t.order_id and o.checked_in and not t.used;

-- 2) public site may read the instructions
grant select (instructions_text) on public.event_settings to anon, authenticated;

-- 3) updated functions
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
    exit when not exists (select 1 from public.orders where ticket_code = c)
          and not exists (select 1 from public.tickets where code = c);
  end loop;
  return c;
end $$;

-- QR code -> order id. Orders made before v2 also match by an old per-person code.
create or replace function public._order_for_code(p_code text) returns bigint
language sql stable set search_path = public, pg_temp as $$
  select coalesce((select id from public.orders where ticket_code = p_code),
                  (select order_id from public.tickets where code = p_code));
$$;

revoke all on function public._order_for_code(text) from public, anon, authenticated;

-- ---------- public: create_order ----------
-- Price comes from ticket_types, never the client. Errors are plain codes the page maps to messages.
-- One QR code per order (admits everyone on it); one Aadhaar image per person.
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[]);   -- pre-v2 signature (no Aadhaar)
create or replace function public.create_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_payer_name text, p_screenshot_path text, p_names text[], p_id_paths text[]
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

  -- one Aadhaar image per person: uploaded through the public uploader, all different, never used before
  if p_id_paths is null or coalesce(array_length(p_id_paths, 1), 0) <> p_qty
     or (select count(distinct x) from unnest(p_id_paths) x) <> p_qty then
    raise exception 'BAD_IDS';
  end if;
  for i in 1..p_qty loop
    if p_id_paths[i] is null or p_id_paths[i] !~ '^[0-9a-f-]{36}\.jpg$'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'ids' and o.name = p_id_paths[i])
       or exists (select 1 from public.tickets where id_path = p_id_paths[i]) then
      raise exception 'BAD_IDS:%', i;
    end if;
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

  insert into public.orders (order_no, token, ticket_code, type_id, type_name, unit_price, qty, amount,
                             buyer_name, email, phone, payer_name, screenshot_path, status, source)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, t.price, p_qty,
          t.price * p_qty, v_name, v_email, v_phone, v_payer, p_screenshot_path, 'pending', 'online')
  returning * into v_order;

  for i in 1..p_qty loop
    insert into public.tickets (order_id, attendee_name, id_path)
    values (v_order.id, btrim(p_names[i]), p_id_paths[i]);
  end loop;

  return v_order.token;
end $$;
revoke all on function public.create_order(bigint,int,text,text,text,text,text,text[],text[]) from public, anon, authenticated;
grant execute on function public.create_order(bigint,int,text,text,text,text,text,text[],text[]) to anon, authenticated;

-- ---------- public: get_order (by unguessable token) ----------
-- Returns the people's names, and the QR code only once the order is approved. Never IDs or screenshots.
create or replace function public.get_order(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype;
begin
  if p_token is null or length(p_token) <> 24 then return null; end if;
  select * into o from public.orders where token = p_token;
  if not found then return null; end if;
  return jsonb_build_object(
    'order_no', o.order_no, 'status', o.status, 'reject_reason', o.reject_reason,
    'type_id', o.type_id, 'type_name', o.type_name, 'qty', o.qty, 'amount', o.amount,
    'buyer_name', o.buyer_name, 'email', o.email, 'created_at', o.created_at,
    'accent_color', (select accent_color from public.ticket_types where id = o.type_id),
    'people', (select coalesce(jsonb_agg(attendee_name order by id), '[]'::jsonb) from public.tickets where order_id = o.id),
    'code', case when o.status = 'approved' then o.ticket_code end,
    'checked_in', o.checked_in);
end $$;
revoke all on function public.get_order(text) from public, anon, authenticated;
grant execute on function public.get_order(text) to anon, authenticated;

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

  insert into public.orders (order_no, token, ticket_code, type_id, type_name, unit_price, qty, amount, buyer_name, email,
                             phone, payer_name, status, source, approved_at)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, t.price, p_qty,
          coalesce(p_amount, t.price * p_qty), btrim(p_buyer_name), v_email, btrim(coalesce(p_phone, '')),
          'manual', 'approved', 'manual', now())
  returning * into o;
  for i in 1..p_qty loop
    insert into public.tickets (order_id, attendee_name) values (o.id, btrim(p_names[i]));
  end loop;
  return jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'token', o.token);
end $$;
revoke all on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int) from public, anon, authenticated;
grant execute on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int) to authenticated;

-- ---------- scanner: check_in / undo / stats / recent ----------
-- One QR per order: a valid scan admits everyone on the order at once.
-- Returns result + names (array) + count + type_name (+ used_at when already used).
create or replace function public.check_in(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code  text := upper(btrim(coalesce(p_code, '')));
  v_who   text := coalesce(auth.jwt() ->> 'email', 'unknown');
  v_id    bigint; o public.orders%rowtype; v_names jsonb;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  v_id := public._order_for_code(v_code);
  if v_id is null then
    insert into public.scan_log (code, result, scanned_by) values (left(v_code, 40), 'invalid', v_who);
    return jsonb_build_object('result', 'invalid');
  end if;
  select * into o from public.orders where id = v_id;
  select coalesce(jsonb_agg(attendee_name order by id), '[]'::jsonb) into v_names from public.tickets where order_id = o.id;

  if o.status <> 'approved' then
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'not_valid', v_who);
    return jsonb_build_object('result', 'not_valid', 'names', v_names, 'count', jsonb_array_length(v_names), 'type_name', o.type_name);
  end if;

  update public.orders set checked_in = true, checked_in_at = now(), checked_in_by = v_who
   where id = o.id and checked_in = false
   returning * into o;
  if found then
    update public.tickets set used = true, used_at = o.checked_in_at, used_by = v_who where order_id = o.id;
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'ok', v_who);
    return jsonb_build_object('result', 'ok', 'names', v_names, 'count', jsonb_array_length(v_names),
                              'type_name', o.type_name, 'order_no', o.order_no, 'code', v_code, 'used_at', o.checked_in_at);
  end if;
  select * into o from public.orders where id = v_id;
  insert into public.scan_log (code, result, scanned_by) values (v_code, 'already_used', v_who);
  return jsonb_build_object('result', 'already_used', 'names', v_names, 'count', jsonb_array_length(v_names),
                            'type_name', o.type_name, 'order_no', o.order_no, 'code', v_code, 'used_at', o.checked_in_at);
end $$;
revoke all on function public.check_in(text) from public, anon, authenticated;
grant execute on function public.check_in(text) to authenticated;

-- Undo the calling user's most recent successful check-in (the whole group becomes un-checked).
create or replace function public.undo_check_in() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_who text := coalesce(auth.jwt() ->> 'email', 'unknown'); l public.scan_log%rowtype; v_id bigint; v_names jsonb;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  select * into l from public.scan_log
   where result = 'ok' and undone = false and scanned_by = v_who
   order by id desc limit 1 for update;
  if not found then return jsonb_build_object('result', 'nothing_to_undo'); end if;
  v_id := public._order_for_code(l.code);
  update public.orders set checked_in = false, checked_in_at = null, checked_in_by = null where id = v_id;
  update public.tickets set used = false, used_at = null, used_by = null where order_id = v_id;
  update public.scan_log set undone = true where id = l.id;
  insert into public.scan_log (code, result, scanned_by) values (l.code, 'undone', v_who);
  select coalesce(jsonb_agg(attendee_name order by id), '[]'::jsonb) into v_names from public.tickets where order_id = v_id;
  return jsonb_build_object('result', 'undone', 'code', l.code, 'names', v_names, 'count', jsonb_array_length(v_names));
end $$;
revoke all on function public.undo_check_in() from public, anon, authenticated;
grant execute on function public.undo_check_in() to authenticated;

drop function if exists public.recent_scans(int);   -- return columns changed in v2
create or replace function public.recent_scans(p_limit int default 20)
returns table (code text, result text, names text, people int, type_name text, created_at timestamptz, undone boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  return query
    select l.code, l.result,
           (select string_agg(t.attendee_name, ', ' order by t.id) from public.tickets t where t.order_id = x.oid),
           (select count(*)::int from public.tickets t where t.order_id = x.oid),
           o.type_name, l.created_at, l.undone
    from public.scan_log l
    left join lateral (select public._order_for_code(l.code) as oid) x on true
    left join public.orders o on o.id = x.oid
    order by l.id desc limit least(greatest(coalesce(p_limit, 20), 1), 100);
end $$;
revoke all on function public.recent_scans(int) from public, anon, authenticated;
grant execute on function public.recent_scans(int) to authenticated;

-- 4) private bucket for Aadhaar photos (public upload only, admin read)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ids', 'ids', false, 3145728, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg'];

drop policy if exists "ids public upload" on storage.objects;
create policy "ids public upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'ids' and name ~ '^[0-9a-f-]{36}\.jpg$');
drop policy if exists "ids admin read" on storage.objects;
create policy "ids admin read" on storage.objects for select to authenticated
  using (bucket_id = 'ids' and public.is_admin());
drop policy if exists "ids admin delete" on storage.objects;
create policy "ids admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'ids' and public.is_admin());

-- 5) defaults: ticket header shows the head count; starter instructions
update public.event_settings
   set ticket_design = jsonb_set(ticket_design, '{header_text}', '"ADMIT {count}"')
 where id = 1 and ticket_design ->> 'header_text' = 'ADMIT ONE';

-- v2: starter instructions panel (only if still empty; edit in Admin > Event)
update public.event_settings
   set instructions_text = $i$• Children are not allowed.
• Every person on the ticket must carry their original Aadhaar card.
• One QR code admits everyone named on the ticket. Please arrive together.$i$
 where id = 1 and instructions_text = '';
