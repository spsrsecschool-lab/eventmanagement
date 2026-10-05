-- 16_preview_image.sql : link-preview image (the picture under a shared link on WhatsApp etc.) uploadable in Admin > Event.
-- Paste & run once in the Supabase SQL editor. Safe to re-run.
alter table public.event_settings add column if not exists og_image_path text not null default '';
grant select (og_image_path) on public.event_settings to anon, authenticated;
