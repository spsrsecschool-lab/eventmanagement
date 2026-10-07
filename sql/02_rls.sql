-- 02_rls.sql : lock everything down, then grant only what each role needs. Safe to re-run.
-- Roles: anon (public buyers) | authenticated with app_metadata.role = 'admin' | 'scanner'.

-- Helper checks. They also confirm the auth user still exists and is not banned,
-- so deleting a scanner login takes effect immediately (not after the JWT expires).
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'admin'
     and exists (select 1 from auth.users u
                 where u.id = auth.uid() and u.deleted_at is null
                   and (u.banned_until is null or u.banned_until < now()));
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') in ('admin','scanner')
     and exists (select 1 from auth.users u
                 where u.id = auth.uid() and u.deleted_at is null
                   and (u.banned_until is null or u.banned_until < now()));
$$;

revoke all on function public.is_admin() from public;
revoke all on function public.is_staff() from public;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.is_staff() to anon, authenticated;

-- Start from zero: nobody has anything unless granted below.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

alter table public.event_settings enable row level security;
alter table public.ticket_types   enable row level security;
alter table public.orders         enable row level security;
alter table public.tickets        enable row level security;
alter table public.email_log      enable row level security;
alter table public.scan_log       enable row level security;

-- ---------- event_settings ----------
-- Everyone may read the public columns. email_templates is NOT granted to anyone
-- (admin reads it through admin_get_email_templates(); functions use the service role).
grant select (id, name, date_text, venue, description, contact_phone, contact_email,
              payment_instructions, terms_text, sales_open, sales_start, sales_end,
              closed_message, max_per_order, logo_path, banner_path, payment_qr_path, instructions_text, theme, ticket_design, updated_at)
  on public.event_settings to anon, authenticated;
grant update on public.event_settings to authenticated;

drop policy if exists es_public_read on public.event_settings;
create policy es_public_read on public.event_settings for select to anon, authenticated using (true);
drop policy if exists es_admin_update on public.event_settings;
create policy es_admin_update on public.event_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- ticket_types ----------
grant select (id, name, description, price, capacity, payment_qr_path, accent_color, active, sort_order)
  on public.ticket_types to anon;
grant select, insert, update, delete on public.ticket_types to authenticated;

drop policy if exists tt_public_read on public.ticket_types;
create policy tt_public_read on public.ticket_types for select to anon, authenticated using (active);
drop policy if exists tt_admin_all on public.ticket_types;
create policy tt_admin_all on public.ticket_types for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant usage on sequence public.ticket_types_id_seq to authenticated;

-- ---------- orders / tickets / logs : admin read only (writes go through RPCs) ----------
grant select on public.orders, public.tickets, public.email_log, public.scan_log to authenticated;
grant update (email) on public.orders to authenticated;   -- "Edit email address"
grant update (consent_ok) on public.orders to authenticated;   -- "Consent form received" tick (admin only, by RLS)

drop policy if exists orders_admin_read on public.orders;
create policy orders_admin_read on public.orders for select to authenticated using (public.is_admin());
drop policy if exists orders_admin_upd on public.orders;
create policy orders_admin_upd on public.orders for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists tickets_admin_read on public.tickets;
create policy tickets_admin_read on public.tickets for select to authenticated using (public.is_admin());
drop policy if exists email_log_admin_read on public.email_log;
create policy email_log_admin_read on public.email_log for select to authenticated using (public.is_admin());
drop policy if exists scan_log_admin_read on public.scan_log;
create policy scan_log_admin_read on public.scan_log for select to authenticated using (public.is_admin());

-- ===== v3 grants =====
grant select (upi_id, dandiya_enabled, dandiya_rent, dandiya_deposit, dandiya_max, dandiya_qrs)
  on public.event_settings to anon, authenticated;
grant select (persons_per_unit, person_labels, unit_label, payment_qrs) on public.ticket_types to anon;
grant select (group_prices) on public.ticket_types to anon;
grant select (og_image_path) on public.event_settings to anon, authenticated;
grant select (staff_child_price, staff_max_children) on public.event_settings to anon, authenticated;

-- venue map + staff booking settings. staff_key is NOT granted: the admin reads it through admin_staff_key().
grant select (venue_map, staff_enabled, staff_discount, staff_max_people, staff_qrs)
  on public.event_settings to anon, authenticated;

alter table public.dandiya_rentals enable row level security;
grant select on public.dandiya_rentals to authenticated;
grant update (deposit_refunded) on public.dandiya_rentals to authenticated;
drop policy if exists dandiya_admin_read on public.dandiya_rentals;
create policy dandiya_admin_read on public.dandiya_rentals for select to authenticated using (public.is_admin());
drop policy if exists dandiya_admin_upd on public.dandiya_rentals;
create policy dandiya_admin_upd on public.dandiya_rentals for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ===== Realtime: admin Orders tab updates instantly (RLS still applies: only admins receive rows) =====
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.orders;          exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.dandiya_rentals; exception when duplicate_object then null; end;
  end if;
end $$;
