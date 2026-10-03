-- 13_staff_booking.sql : staff booking page (secret link, 20% off, max 2 people per staff member).
-- Also adds the venue map column if sql/11 was skipped. Paste & run once in the Supabase SQL editor. Safe to re-run.

-- venue map; staff booking (secret link, discount, max people per staff member matched by mobile or email)
alter table public.event_settings add column if not exists venue_map        text not null default '';   -- Google Maps link or address
alter table public.event_settings add column if not exists staff_enabled    boolean not null default false;
alter table public.event_settings add column if not exists staff_discount   int not null default 20;      -- percent off every pass
alter table public.event_settings add column if not exists staff_max_people int not null default 2;
alter table public.event_settings add column if not exists staff_key        text not null default '';     -- secret in the staff link; never readable by buyers
alter table public.event_settings add column if not exists staff_qrs        jsonb not null default '{}'::jsonb;  -- {"240":"path","480":"path"}
do $$ begin
  alter table public.event_settings add constraint es_staff_discount_chk check (staff_discount between 0 and 90);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.event_settings add constraint es_staff_max_chk check (staff_max_people between 1 and 20);
exception when duplicate_object then null; end $$;
alter table public.orders add column if not exists is_staff boolean not null default false;

-- venue map + staff booking settings. staff_key is NOT granted: the admin reads it through admin_staff_key().
grant select (venue_map, staff_enabled, staff_discount, staff_max_people, staff_qrs)
  on public.event_settings to anon, authenticated;

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

-- Staff page: is this link valid? Returns {discount, max_people} or null. Never returns the key.
create or replace function public.staff_check(p_key text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('discount', staff_discount, 'max_people', staff_max_people)
    from public.event_settings
   where id = 1 and staff_enabled and staff_key <> '' and staff_key = p_key;
$$;
revoke all on function public.staff_check(text) from public, anon, authenticated;
grant execute on function public.staff_check(text) to anon, authenticated;

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
drop function if exists public.create_order(bigint,int,text,text,text,text,text,text[],text[]);   -- pre-staff signature
create or replace function public.create_order(
  p_type_id bigint, p_qty int, p_buyer_name text, p_email text, p_phone text,
  p_payer_name text, p_screenshot_path text, p_names text[], p_id_paths text[], p_staff_key text default null
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
  v_staff boolean := p_staff_key is not null; v_price int; v_used int;
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

  v_price := t.price;
  if v_staff then
    if not s.staff_enabled or s.staff_key = '' or p_staff_key is distinct from s.staff_key then raise exception 'BAD_STAFF_LINK'; end if;
    v_price := round(t.price * (100 - s.staff_discount) / 100.0);
    -- one staff member = same mobile (last 10 digits) or same email. Lock both so two tabs cannot pass the check together.
    perform pg_advisory_xact_lock(hashtext('staff-phone:' || right(regexp_replace(v_phone, '\D', '', 'g'), 10)));
    perform pg_advisory_xact_lock(hashtext('staff-email:' || v_email));
    v_used := public._staff_used(v_email, v_phone);
    if v_used + v_people > s.staff_max_people then
      raise exception 'STAFF_LIMIT:%', greatest(s.staff_max_people - v_used, 0);
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
  values ('ORD-' || nextval('public.order_no_seq'), public._rand_token(), public._new_ticket_code(), t.id, t.name, v_price, p_qty,
          v_price * p_qty, v_name, v_email, v_phone, v_payer, p_screenshot_path, 'pending', 'online', v_staff)
  returning * into v_order;

  for i in 1..v_people loop
    insert into public.tickets (order_id, attendee_name, id_path, slot)
    values (v_order.id, btrim(p_names[i]), p_id_paths[i],
            public._slot_label(t, (i - 1) / t.persons_per_unit + 1, (i - 1) % t.persons_per_unit + 1));
  end loop;

  return v_order.token;
end $$;
revoke all on function public.create_order(bigint,int,text,text,text,text,text,text[],text[],text) from public, anon, authenticated;
grant execute on function public.create_order(bigint,int,text,text,text,text,text,text[],text[],text) to anon, authenticated;
