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

create or replace function public._seats_taken(p_type_id bigint) returns int
language sql stable set search_path = public, pg_temp as $$
  select coalesce(sum(qty), 0)::int from public.orders
  where type_id = p_type_id and status in ('pending','approved');
$$;

revoke all on function public._rand_token()        from public, anon, authenticated;
revoke all on function public._new_ticket_code()   from public, anon, authenticated;
revoke all on function public._seats_taken(bigint) from public, anon, authenticated;
revoke all on function public._order_for_code(text)  from public, anon, authenticated;

-- ---------- public: ticket types with seats left (v3: people per pass, per-amount QRs) ----------
drop function if exists public.public_ticket_types();   -- return columns changed (v3, group prices)
create or replace function public.public_ticket_types()
returns table (id bigint, name text, description text, price int, capacity int,
               payment_qr_path text, accent_color text, sort_order int, remaining int,
               persons_per_unit int, person_labels text[], unit_label text, payment_qrs jsonb, group_prices jsonb)
language sql stable security definer set search_path = public, pg_temp as $$
  select t.id, t.name, t.description, t.price, t.capacity, t.payment_qr_path, t.accent_color,
         t.sort_order, greatest(t.capacity - public._seats_taken(t.id), 0),
         t.persons_per_unit, t.person_labels, t.unit_label, t.payment_qrs, t.group_prices
  from public.ticket_types t
  where t.active
  order by t.sort_order, t.id;
$$;
revoke all on function public.public_ticket_types() from public, anon, authenticated;
grant execute on function public.public_ticket_types() to anon, authenticated;

-- label of person k (1-based) in pass u, e.g. "Couple 2 · Female" or "Female"
create or replace function public._slot_label(t public.ticket_types, u int, k int) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case when t.persons_per_unit > 1
              then coalesce(nullif(t.unit_label, ''), 'Group') || ' ' || u || ' · ' || coalesce(t.person_labels[k], 'Person ' || k)
              else coalesce(t.person_labels[1], '') end;
$$;
revoke all on function public._slot_label(public.ticket_types,int,int) from public, anon, authenticated;

-- total for q passes: the group price for q if set, else price x q
create or replace function public._type_total(t public.ticket_types, q int) returns int
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(nullif(t.group_prices ->> q::text, '')::int, t.price * q);
$$;
revoke all on function public._type_total(public.ticket_types,int) from public, anon, authenticated;

-- who each person is: 'student' (girls of the school; signed consent form at school), 'guest' (parent / guest),
-- or 'child' (staff booking only: a staff member's own child, at the staff child price)
create or replace function public._roles_ok(p_roles text[], n int) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select p_roles is null or coalesce(array_length(p_roles, 1), 0) = 0
      or (array_length(p_roles, 1) = n and not exists (select 1 from unnest(p_roles) r where r is null or r not in ('student', 'guest', 'child')));
$$;
revoke all on function public._roles_ok(text[],int) from public, anon, authenticated;

-- ---------- staff booking helpers ----------
-- People already booked by one staff member (pending + approved staff orders, same email or same mobile).
create or replace function public._staff_used(p_email text, p_phone text) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from public.tickets tk join public.orders o on o.id = tk.order_id
   where o.is_staff and o.status in ('pending', 'approved')
     and (lower(o.email) = lower(btrim(coalesce(p_email, '')))
          or (length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 10
              and right(regexp_replace(o.phone, '\D', '', 'g'), 10) = right(regexp_replace(p_phone, '\D', '', 'g'), 10)));
$$;
revoke all on function public._staff_used(text, text) from public, anon, authenticated;

-- Children already booked by one staff member (same matching as _staff_used).
create or replace function public._staff_children_used(p_email text, p_phone text) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from public.tickets tk join public.orders o on o.id = tk.order_id
   where o.is_staff and o.status in ('pending', 'approved') and tk.slot = 'Child'
     and (lower(o.email) = lower(btrim(coalesce(p_email, '')))
          or (length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 10
              and right(regexp_replace(o.phone, '\D', '', 'g'), 10) = right(regexp_replace(p_phone, '\D', '', 'g'), 10)));
$$;
revoke all on function public._staff_children_used(text, text) from public, anon, authenticated;

-- Staff page: is this link valid? Returns {discount, max_people} or null. Never returns the key.
create or replace function public.staff_check(p_key text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('discount', staff_discount, 'max_people', staff_max_people, 'child_price', staff_child_price,
                            'max_children', staff_max_children)
    from public.event_settings
   where id = 1 and staff_enabled and staff_key <> '' and staff_key = p_key;
$$;
revoke all on function public.staff_check(text) from public, anon, authenticated;
grant execute on function public.staff_check(text) to anon, authenticated;

-- Staff page, before payment: how many more people this staff member (same mobile or email) can book. Null = bad link.
create or replace function public.staff_remaining(p_key text, p_email text, p_phone text) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(staff_max_people - public._staff_used(p_email, p_phone), 0)
    from public.event_settings
   where id = 1 and staff_enabled and staff_key <> '' and staff_key = p_key;
$$;
revoke all on function public.staff_remaining(text, text, text) from public, anon, authenticated;
grant execute on function public.staff_remaining(text, text, text) to anon, authenticated;

-- Same check, with children: {"people": n, "children": n} still bookable. Null = bad link.
create or replace function public.staff_quota(p_key text, p_email text, p_phone text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('people',   greatest(staff_max_people - public._staff_used(p_email, p_phone), 0),
                            'children', greatest(staff_max_children - public._staff_children_used(p_email, p_phone), 0))
    from public.event_settings
   where id = 1 and staff_enabled and staff_key <> '' and staff_key = p_key;
$$;
revoke all on function public.staff_quota(text, text, text) from public, anon, authenticated;
grant execute on function public.staff_quota(text, text, text) to anon, authenticated;

-- Admin: the secret staff link key (made on first use). p_new = true makes a new one; the old link stops working.
create or replace function public.admin_staff_key(p_new boolean default false) returns text
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare k text;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  update public.event_settings set staff_key = public._rand_token()
   where id = 1 and (p_new or staff_key = '');
  select staff_key into k from public.event_settings where id = 1;
  return k;
end $$;
revoke all on function public.admin_staff_key(boolean) from public, anon, authenticated;
grant execute on function public.admin_staff_key(boolean) to authenticated;

-- ---------- public: create_order ----------
-- Price comes from ticket_types, never the client. Errors are plain codes the page maps to messages.
-- One QR code per order (admits everyone on it); qty = passes; people = qty x persons_per_unit,
-- each with a name (Aadhaar images optional, no longer asked for).
-- p_staff_key (from the secret staff link): staff discount, and at most staff_max_people people per staff member,
-- counted over their pending + approved staff orders by the same mobile number or email.
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[]);          -- pre-v2 signature (no Aadhaar)
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[],text[]);        -- pre-staff signature
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[],text[],text);   -- pre-roles signature
create or replace function public.create_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_payer_name text, p_screenshot_path text, p_names text[], p_id_paths text[], p_staff_key text default null,
  p_roles text[] default null
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
  v_left  int; v_people int; i int; nm text;
  v_staff boolean := p_staff_key is not null; v_price int; v_used int; v_total int;
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

  -- Lock the ticket type row: concurrent buyers of this type queue here, so seats cannot be oversold.
  select * into t from public.ticket_types where id = p_type_id and active for update;
  if not found then raise exception 'TYPE_UNAVAILABLE'; end if;
  v_people := p_qty * t.persons_per_unit;

  if p_names is null or coalesce(array_length(p_names, 1), 0) <> v_people then raise exception 'BAD_ATTENDEES'; end if;
  foreach nm in array p_names loop
    if length(btrim(coalesce(nm, ''))) < 2 or length(nm) > 80 then raise exception 'BAD_ATTENDEES'; end if;
  end loop;
  if not public._roles_ok(p_roles, v_people) then raise exception 'BAD_ATTENDEES'; end if;
  -- child passes: staff booking only, one person per pass
  if 'child' = any(coalesce(p_roles, '{}')) and (not v_staff or t.persons_per_unit <> 1) then raise exception 'BAD_ATTENDEES'; end if;

  v_price := t.price; v_total := public._type_total(t, p_qty);   -- group price for this many passes
  if v_staff then
    if not s.staff_enabled or s.staff_key = '' or p_staff_key is distinct from s.staff_key then raise exception 'BAD_STAFF_LINK'; end if;
    v_price := round(t.price * (100 - s.staff_discount) / 100.0);   -- staff: discount per adult, fixed price per child
    v_total := (select coalesce(sum(case when r = 'child' then s.staff_child_price else v_price end), 0)::int
                  from unnest(case when coalesce(array_length(p_roles, 1), 0) = 0 then array_fill('guest'::text, array[v_people]) else p_roles end) r);
    -- one staff member = same mobile (last 10 digits) or same email. Lock both so two tabs cannot pass the check together.
    perform pg_advisory_xact_lock(hashtext('staff-phone:' || right(regexp_replace(v_phone, '\D', '', 'g'), 10)));
    perform pg_advisory_xact_lock(hashtext('staff-email:' || v_email));
    v_used := public._staff_used(v_email, v_phone);
    if v_used + v_people > s.staff_max_people then
      raise exception 'STAFF_LIMIT:%', greatest(s.staff_max_people - v_used, 0);
    end if;
    v_used := public._staff_children_used(v_email, v_phone);   -- children: at most staff_max_children per staff member
    if v_used + (select count(*) from unnest(coalesce(p_roles, '{}')) r where r = 'child') > s.staff_max_children then
      raise exception 'STAFF_CHILD_LIMIT:%', greatest(s.staff_max_children - v_used, 0);
    end if;
  end if;

  -- Aadhaar images are no longer collected (the page sends an empty list). If a list is sent, it must still be
  -- one image per person: uploaded through the public uploader, all different, never used before.
  if coalesce(array_length(p_id_paths, 1), 0) = 0 then
    p_id_paths := array_fill(null::text, array[v_people]);
  elsif array_length(p_id_paths, 1) <> v_people
     or (select count(distinct x) from unnest(p_id_paths) x) <> v_people then
    raise exception 'BAD_IDS';
  else for i in 1..v_people loop
    if p_id_paths[i] is null or p_id_paths[i] !~ '^[0-9a-f-]{36}\.jpg$'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'ids' and o.name = p_id_paths[i])
       or exists (select 1 from public.tickets where id_path = p_id_paths[i]) then
      raise exception 'BAD_IDS:%', i;
    end if;
  end loop; end if;

  -- screenshot must be a path uploaded through the public uploader and not used anywhere else
  if p_screenshot_path is null or p_screenshot_path !~ '^[0-9a-f-]{36}\.jpg$'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'screenshots' and o.name = p_screenshot_path)
     or exists (select 1 from public.orders where screenshot_path = p_screenshot_path)
     or exists (select 1 from public.dandiya_rentals where screenshot_path = p_screenshot_path) then
    raise exception 'BAD_SCREENSHOT';
  end if;

  v_left := t.capacity - public._seats_taken(t.id);
  if v_left <= 0 then raise exception 'SOLD_OUT'; end if;
  if p_qty > v_left then raise exception 'NOT_ENOUGH_SEATS:%', v_left; end if;

  if (select count(*) from public.orders where lower(email) = v_email and status = 'pending') >= 3 then
    raise exception 'TOO_MANY_PENDING';
  end if;

  insert into public.orders (order_no, token, ticket_code, type_id, type_name, unit_price, qty, amount,
                             buyer_name, email, phone, payer_name, screenshot_path, status, source, is_staff)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, round(v_total::numeric / p_qty), p_qty,
          v_total, v_name, v_email, v_phone, v_payer, p_screenshot_path, 'pending', 'online', v_staff)
  returning * into v_order;

  for i in 1..v_people loop
    insert into public.tickets (order_id, attendee_name, id_path, slot)
    values (v_order.id, btrim(p_names[i]), p_id_paths[i],
            case when p_roles[i] = 'student' then 'Student' when p_roles[i] = 'child' then 'Child'
                 else nullif(public._slot_label(t, (i - 1) / t.persons_per_unit + 1, (i - 1) % t.persons_per_unit + 1), '') end);
  end loop;

  return v_order.token;
end $$;
revoke all on function public.create_order(bigint,int,text,text,text,text,text,text[],text[],text,text[]) from public, anon, authenticated;
grant execute on function public.create_order(bigint,int,text,text,text,text,text,text[],text[],text,text[]) to anon, authenticated;

-- ---------- public: get_order (by unguessable token) ----------
-- Names (+ slot labels), the QR code only once approved, and the latest dandiya rental. Never IDs or screenshots.
create or replace function public.get_order(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare o public.orders%rowtype; d public.dandiya_rentals%rowtype;
begin
  if p_token is null or length(p_token) <> 24 then return null; end if;
  select * into o from public.orders where token = p_token;
  if not found then return null; end if;
  select * into d from public.dandiya_rentals where order_id = o.id order by id desc limit 1;
  return jsonb_build_object(
    'order_no', o.order_no, 'status', o.status, 'reject_reason', o.reject_reason,
    'type_id', o.type_id, 'type_name', o.type_name, 'qty', o.qty, 'amount', o.amount,
    'buyer_name', o.buyer_name, 'email', o.email, 'created_at', o.created_at,
    'accent_color', (select accent_color from public.ticket_types where id = o.type_id),
    'people', (select coalesce(jsonb_agg(attendee_name order by id), '[]'::jsonb) from public.tickets where order_id = o.id),
    'consent_ok', o.consent_ok,
    'slots',  (select coalesce(jsonb_agg(coalesce(slot, '') order by id), '[]'::jsonb) from public.tickets where order_id = o.id),
    'code', case when o.status = 'approved' then o.ticket_code end,
    'checked_in', o.checked_in,
    'dandiya', case when d.id is null then null else jsonb_build_object(
        'pairs', d.pairs, 'amount', d.amount, 'status', d.status, 'reject_reason', d.reject_reason,
        'deposit_refunded', d.deposit_refunded, 'created_at', d.created_at) end);
end $$;
revoke all on function public.get_order(text) from public, anon, authenticated;
grant execute on function public.get_order(text) to anon, authenticated;

-- ---------- public: request a dandiya rental for an approved order ----------
create or replace function public.request_dandiya(p_token text, p_pairs int, p_payer_name text, p_screenshot_path text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.event_settings%rowtype; o public.orders%rowtype; v_payer text := btrim(coalesce(p_payer_name, ''));
begin
  select * into s from public.event_settings where id = 1;
  if not s.dandiya_enabled then raise exception 'DANDIYA_OFF'; end if;
  if p_token is null or length(p_token) <> 24 then raise exception 'NOT_FOUND'; end if;
  select * into o from public.orders where token = p_token for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'approved' then raise exception 'ORDER_NOT_APPROVED'; end if;
  if exists (select 1 from public.dandiya_rentals where order_id = o.id and status in ('pending','approved')) then
    raise exception 'DANDIYA_EXISTS';
  end if;
  if p_pairs is null or p_pairs < 1 or p_pairs > s.dandiya_max then raise exception 'BAD_PAIRS:%', s.dandiya_max; end if;
  if length(v_payer) < 2 or length(v_payer) > 80 then raise exception 'BAD_PAYER'; end if;
  if p_screenshot_path is null or p_screenshot_path !~ '^[0-9a-f-]{36}\.jpg$'
     or not exists (select 1 from storage.objects x where x.bucket_id = 'screenshots' and x.name = p_screenshot_path)
     or exists (select 1 from public.orders where screenshot_path = p_screenshot_path)
     or exists (select 1 from public.dandiya_rentals where screenshot_path = p_screenshot_path) then
    raise exception 'BAD_SCREENSHOT';
  end if;
  insert into public.dandiya_rentals (order_id, pairs, amount, payer_name, screenshot_path)
  values (o.id, p_pairs, p_pairs * (s.dandiya_rent + s.dandiya_deposit), v_payer, p_screenshot_path);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.request_dandiya(text,int,text,text) from public, anon, authenticated;
grant execute on function public.request_dandiya(text,int,text,text) to anon, authenticated;

-- ---------- admin: approve / reject a dandiya rental ----------
create or replace function public.admin_set_dandiya_status(p_id bigint, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.dandiya_rentals%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status not in ('pending','approved','rejected') then raise exception 'BAD_STATUS'; end if;
  select * into d from public.dandiya_rentals where id = p_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  update public.dandiya_rentals set
    status = p_status,
    reject_reason = case when p_status = 'rejected' then nullif(btrim(coalesce(p_reason, '')), '') else null end,
    approved_at   = case when p_status = 'approved' then now() else null end
  where id = d.id returning * into d;
  return to_jsonb(d) - 'screenshot_path';
end $$;
revoke all on function public.admin_set_dandiya_status(bigint,text,text) from public, anon, authenticated;
grant execute on function public.admin_set_dandiya_status(bigint,text,text) to authenticated;

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

  -- a pass with a student is issued only after her signed consent form is received at school
  if p_status = 'approved' and not o.consent_ok
     and exists (select 1 from public.tickets where order_id = o.id and slot = 'Student') then
    raise exception 'CONSENT_MISSING';
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
-- Offline / cash sale or complimentary ticket. Email is optional (no email = show or print the ticket instead).
drop function if exists public.admin_create_manual_order(bigint,int,text,text,text,text[],int);          -- pre-roles signature
drop function if exists public.admin_create_manual_order(bigint,int,text,text,text,text[],int,text[]);   -- pre-consent signature
create or replace function public.admin_create_manual_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_names text[], p_amount int default null, p_roles text[] default null, p_consent boolean default false
) returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare t public.ticket_types%rowtype; o public.orders%rowtype; i int; nm text; v_people int;
        v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 50 then raise exception 'BAD_QTY'; end if;
  if length(btrim(coalesce(p_buyer_name, ''))) < 2 then raise exception 'BAD_NAME'; end if;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'BAD_EMAIL'; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'BAD_AMOUNT'; end if;

  select * into t from public.ticket_types where id = p_type_id for update;
  if not found then raise exception 'TYPE_UNAVAILABLE'; end if;
  v_people := p_qty * t.persons_per_unit;
  if p_names is null or coalesce(array_length(p_names, 1), 0) <> v_people then raise exception 'BAD_ATTENDEES'; end if;
  foreach nm in array p_names loop
    if length(btrim(coalesce(nm, ''))) < 2 then raise exception 'BAD_ATTENDEES'; end if;
  end loop;
  if not public._roles_ok(p_roles, v_people) then raise exception 'BAD_ATTENDEES'; end if;
  if 'student' = any(coalesce(p_roles, '{}')) and not coalesce(p_consent, false) then raise exception 'CONSENT_MISSING'; end if;
  if p_qty > t.capacity - public._seats_taken(t.id) then
    raise exception 'NOT_ENOUGH_SEATS:%', greatest(t.capacity - public._seats_taken(t.id), 0);
  end if;

  insert into public.orders (order_no, token, ticket_code, type_id, type_name, unit_price, qty, amount, buyer_name, email,
                             phone, payer_name, status, source, approved_at, consent_ok)
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, t.price, p_qty,
          coalesce(p_amount, public._type_total(t, p_qty)), btrim(p_buyer_name), v_email, btrim(coalesce(p_phone, '')),
          'manual', 'approved', 'manual', now(), coalesce(p_consent, false))
  returning * into o;
  for i in 1..v_people loop
    insert into public.tickets (order_id, attendee_name, slot)
    values (o.id, btrim(p_names[i]), case when p_roles[i] = 'student' then 'Student' when p_roles[i] = 'child' then 'Child'
                 else nullif(public._slot_label(t, (i - 1) / t.persons_per_unit + 1, (i - 1) % t.persons_per_unit + 1), '') end);
  end loop;
  return jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'token', o.token);
end $$;
revoke all on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int,text[],boolean) from public, anon, authenticated;
grant execute on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int,text[],boolean) to authenticated;

-- ---------- admin: dandiya sticks sold offline with a pass (cash). Recorded as an approved rental. ----------
create or replace function public.admin_add_dandiya(p_order_id bigint, p_pairs int, p_amount int default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.event_settings%rowtype; o public.orders%rowtype; d public.dandiya_rentals%rowtype;
begin
  if not public.is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into s from public.event_settings where id = 1;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'approved' then raise exception 'ORDER_NOT_APPROVED'; end if;
  if p_pairs is null or p_pairs < 1 or p_pairs > greatest(s.dandiya_max, 1) then raise exception 'BAD_PAIRS:%', s.dandiya_max; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'BAD_AMOUNT'; end if;
  if exists (select 1 from public.dandiya_rentals where order_id = o.id and status in ('pending', 'approved')) then
    raise exception 'DANDIYA_EXISTS';
  end if;
  insert into public.dandiya_rentals (order_id, pairs, amount, payer_name, status, approved_at)
  values (o.id, p_pairs, coalesce(p_amount, p_pairs * (s.dandiya_rent + s.dandiya_deposit)), 'Cash (offline)', 'approved', now())
  returning * into d;
  return to_jsonb(d);
end $$;
revoke all on function public.admin_add_dandiya(bigint,int,int) from public, anon, authenticated;
grant execute on function public.admin_add_dandiya(bigint,int,int) to authenticated;

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
-- One QR per order: a valid scan admits everyone on the order at once.
-- Returns result + names (array) + count + type_name (+ used_at when already used) + paid dandiya pairs.
create or replace function public.check_in(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code  text := upper(btrim(coalesce(p_code, '')));
  v_who   text := coalesce(auth.jwt() ->> 'email', 'unknown');
  v_id    bigint; o public.orders%rowtype; v_names jsonb; v_pairs int; v_slots jsonb; v_students int;
begin
  if not public.is_staff() then raise exception 'FORBIDDEN'; end if;
  v_id := public._order_for_code(v_code);
  if v_id is null then
    insert into public.scan_log (code, result, scanned_by) values (left(v_code, 40), 'invalid', v_who);
    return jsonb_build_object('result', 'invalid');
  end if;
  select * into o from public.orders where id = v_id;
  select coalesce(jsonb_agg(attendee_name order by id), '[]'::jsonb), coalesce(jsonb_agg(coalesce(slot, '') order by id), '[]'::jsonb),
         count(*) filter (where slot = 'Student')::int
    into v_names, v_slots, v_students from public.tickets where order_id = o.id;
  select coalesce(sum(pairs), 0)::int into v_pairs from public.dandiya_rentals where order_id = o.id and status = 'approved';

  if o.status <> 'approved' then
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'not_valid', v_who);
    return jsonb_build_object('result', 'not_valid', 'names', v_names, 'slots', v_slots, 'students', v_students, 'count', jsonb_array_length(v_names), 'type_name', o.type_name);
  end if;

  update public.orders set checked_in = true, checked_in_at = now(), checked_in_by = v_who
   where id = o.id and checked_in = false
   returning * into o;
  if found then
    update public.tickets set used = true, used_at = o.checked_in_at, used_by = v_who where order_id = o.id;
    insert into public.scan_log (code, result, scanned_by) values (v_code, 'ok', v_who);
    return jsonb_build_object('result', 'ok', 'names', v_names, 'slots', v_slots, 'students', v_students, 'count', jsonb_array_length(v_names),
                              'type_name', o.type_name, 'order_no', o.order_no, 'code', v_code, 'used_at', o.checked_in_at,
                              'dandiya_pairs', v_pairs);
  end if;
  select * into o from public.orders where id = v_id;
  insert into public.scan_log (code, result, scanned_by) values (v_code, 'already_used', v_who);
  return jsonb_build_object('result', 'already_used', 'names', v_names, 'slots', v_slots, 'students', v_students, 'count', jsonb_array_length(v_names),
                            'type_name', o.type_name, 'order_no', o.order_no, 'code', v_code, 'used_at', o.checked_in_at,
                            'dandiya_pairs', v_pairs);
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
