-- 15_consent.sql : a pass with a student is issued only after her signed consent form is received at school.
-- Adds the "Consent form received" tick in admin. Run once after 14_upgrade_v4.sql. Safe to re-run.

alter table public.orders add column if not exists consent_ok boolean not null default false;
grant update (consent_ok) on public.orders to authenticated;   -- admin only, by RLS

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
    values (o.id, btrim(p_names[i]), case when p_roles[i] = 'student' then 'Student'
                 else nullif(public._slot_label(t, (i - 1) / t.persons_per_unit + 1, (i - 1) % t.persons_per_unit + 1), '') end);
  end loop;
  return jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'token', o.token);
end $$;
revoke all on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int,text[],boolean) from public, anon, authenticated;
grant execute on function public.admin_create_manual_order(bigint,int,text,text,text,text[],int,text[],boolean) to authenticated;
