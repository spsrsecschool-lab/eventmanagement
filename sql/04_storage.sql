-- 04_storage.sql : buckets and policies. Safe to re-run.
--   branding    : PUBLIC read (logo, banner, payment QR images). Only admin can write.
--   screenshots : PRIVATE. Public can only upload (to a random uuid.jpg path); only admin can read.
--   ids         : PRIVATE Aadhaar images from older orders (no longer collected). Admin read only.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', true, 5242880, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/png','image/jpeg','image/webp'];

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('screenshots', 'screenshots', false, 3145728, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 3145728,
  allowed_mime_types = array['image/jpeg'];

-- branding: admin writes (public files are served by the bucket's public URL, no listing policy for anon)
drop policy if exists "branding admin select" on storage.objects;
create policy "branding admin select" on storage.objects for select to authenticated
  using (bucket_id = 'branding' and public.is_admin());
drop policy if exists "branding admin insert" on storage.objects;
create policy "branding admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'branding' and public.is_admin());
drop policy if exists "branding admin update" on storage.objects;
create policy "branding admin update" on storage.objects for update to authenticated
  using (bucket_id = 'branding' and public.is_admin()) with check (bucket_id = 'branding' and public.is_admin());
drop policy if exists "branding admin delete" on storage.objects;
create policy "branding admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'branding' and public.is_admin());

-- screenshots: anyone may upload a new file with a uuid name; nobody but admin can read or list
drop policy if exists "screenshots public upload" on storage.objects;
create policy "screenshots public upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'screenshots' and name ~ '^[0-9a-f-]{36}\.jpg$');
drop policy if exists "screenshots admin read" on storage.objects;
create policy "screenshots admin read" on storage.objects for select to authenticated
  using (bucket_id = 'screenshots' and public.is_admin());
drop policy if exists "screenshots admin delete" on storage.objects;
create policy "screenshots admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'screenshots' and public.is_admin());

-- ids (Aadhaar images): same rules as screenshots. Scanner logins cannot read these.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ids', 'ids', false, 3145728, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg'];

drop policy if exists "ids public upload" on storage.objects;   -- Aadhaar photos are no longer collected (sql/12)
drop policy if exists "ids admin read" on storage.objects;
create policy "ids admin read" on storage.objects for select to authenticated
  using (bucket_id = 'ids' and public.is_admin());
drop policy if exists "ids admin delete" on storage.objects;
create policy "ids admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'ids' and public.is_admin());
