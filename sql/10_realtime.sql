-- 10_realtime.sql : instant updates in Admin > Orders (new orders and dandiya requests appear without refreshing).
-- Run once in the Supabase SQL editor. Safe to re-run. Row Level Security still applies: only admins receive the changes.
do $$
begin
  begin alter publication supabase_realtime add table public.orders;          exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.dandiya_rentals; exception when duplicate_object then null; end;
end $$;
