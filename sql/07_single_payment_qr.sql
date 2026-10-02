-- 07_single_payment_qr.sql : one UPI payment QR for the whole event instead of one per ticket type.
-- Run once on an existing setup (safe to re-run). New setups get this from 01 + 02 as well.

alter table public.event_settings add column if not exists payment_qr_path text;

-- let the public site read it (same as the other public settings columns)
grant select (payment_qr_path) on public.event_settings to anon, authenticated;

-- carry over a QR you already uploaded on a ticket type, if any
update public.event_settings
   set payment_qr_path = (select payment_qr_path from public.ticket_types
                           where payment_qr_path is not null order by sort_order, id limit 1)
 where id = 1 and payment_qr_path is null;
