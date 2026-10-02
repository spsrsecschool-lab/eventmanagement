-- 11_venue_map.sql : venue location on Google Maps (shown on the pass page and in the ticket email).
-- Paste & run once in the Supabase SQL editor. Safe to re-run.
alter table public.event_settings add column if not exists venue_map text not null default '';   -- Google Maps link or full address
grant select (venue_map) on public.event_settings to anon, authenticated;
