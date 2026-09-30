-- 06_make_admin.sql : run ONCE, after creating your admin user.
-- 1) Supabase dashboard > Authentication > Users > Add user (email + password, tick "Auto Confirm User").
-- 2) Put that email below and run. 3) Sign in to the admin site (sign out and in again if already signed in).
update auth.users
   set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
 where email = 'CHANGE_ME@example.com';
-- Should say "UPDATE 1". If it says UPDATE 0, the email does not match a user.
