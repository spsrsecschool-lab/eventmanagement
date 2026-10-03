-- 05_seed.sql : starting content taken from the Dandiya Nights ticket. Safe to re-run:
-- it only fills the row / columns that are still empty, never overwrites admin edits.

insert into public.event_settings (id) values (1) on conflict (id) do nothing;

update public.event_settings set
  name                 = case when name = 'My Event' then 'Dandiya Nights' else name end,
  date_text            = case when date_text = '' then '17th October | 6 PM onwards' else date_text end,
  venue                = case when venue = '' then 'Shiv Public School, Dabua Colony' else venue end,
  description          = case when description = '' then $d$Join us for an evening of music, dance and festive joy at Shiv Public School. Dress up, bring your dandiya sticks and celebrate with us!$d$ else description end,
  payment_instructions = case when payment_instructions = '' then $p$1. Open any UPI app and scan the QR code shown.
2. Pay the exact total amount.
3. Type the name shown in your payment app below, and upload the payment screenshot.
Your ticket will be emailed after we verify the payment.$p$ else payment_instructions end,
  terms_text           = case when terms_text = '' then $t$Tickets are non-refundable and non-transferable. Each ticket admits one person. Carry a valid ID.$t$ else terms_text end,
  theme = case when theme = '{}'::jsonb then $th${
    "mode":"dark","primary":"#f5b83d","background":"#1f0823","card":"#321037","text":"#fdf3e3",
    "accent":"#f5cc6a","button_text":"#2b0a30","radius":14,"font":"Poppins"
  }$th$::jsonb else theme end,
  ticket_design = case when ticket_design = '{}'::jsonb then $td${
    "strip_bg":"#2b0a30","strip_text":"#fff4e0","accent":"#f5cc6a","number_color":"#f9d77a","qr_color":"#2b0a30",
    "header_text":"ADMIT {count}","footer_note":"Bring your school ID",
    "show_type":true,"show_date":true,"show_venue":true,"show_number":true,"show_logo":false
  }$td$::jsonb else ticket_design end,
  email_templates = case when email_templates = '{}'::jsonb then $et${
    "received":{
      "subject":"We received your order {order_no} - {event}",
      "body":"Hi {name},\n\nThank you! We received your order {order_no} for {event} ({qty} x {type}, Rs {amount}).\n\nWe are verifying your payment. Once it is approved, your ticket will be emailed to you.\n\nTrack your order here: {link}\n\n{event}\n{date}\n{venue}"
    },
    "approved":{
      "subject":"Your ticket for {event} ({order_no})",
      "body":"Hi {name},\n\nYour payment is verified. Your ticket(s) for {event} are attached to this email as a PDF.\n\nDate: {date}\nVenue: {venue}\n\nPlease keep the QR code ready at the gate. Each ticket can be used only once.\n\nBackup link to your tickets: {link}"
    },
    "rejected":{
      "subject":"Update on your order {order_no} - {event}",
      "body":"Hi {name},\n\nWe could not verify the payment for order {order_no}.\nReason: {reason}\n\nIf you think this is a mistake, please contact us: {contact_phone} {contact_email}\n\nOrder link: {link}"
    }
  }$et$::jsonb else email_templates end
where id = 1;

-- One starter ticket type, switched OFF so nothing goes on sale by accident.
-- Set its price / seats / payment QR in Admin > Ticket types, then turn it on.
insert into public.ticket_types (name, description, price, capacity, active, sort_order)
select 'General Entry', 'Admits one person', 100, 200, false, 1
where not exists (select 1 from public.ticket_types);

-- v2: one ticket admits the whole group, so the default header shows the head count ({count} -> 3)
update public.event_settings
   set ticket_design = jsonb_set(ticket_design, '{header_text}', '"ADMIT {count}"')
 where id = 1 and ticket_design ->> 'header_text' = 'ADMIT ONE';

-- v2: starter instructions panel (only if still empty; edit in Admin > Event)
update public.event_settings
   set instructions_text = $i$• Children are not allowed.
• One QR code admits everyone named on the ticket. Please arrive together.$i$
 where id = 1 and instructions_text = '';

-- v3: the two passes (added switched OFF; set seats and payment QRs in Admin > Ticket types, then turn them on)
insert into public.ticket_types (name, description, price, capacity, active, sort_order, persons_per_unit, person_labels, unit_label)
select 'Female Solo', 'One pass per woman', 300, 100, false, 10, 1, '{Female}', ''
where not exists (select 1 from public.ticket_types where name = 'Female Solo');
insert into public.ticket_types (name, description, price, capacity, active, sort_order, persons_per_unit, person_labels, unit_label)
select 'Couple Pass', 'One pass admits a couple', 600, 100, false, 20, 2, '{Male,Female}', 'Couple'
where not exists (select 1 from public.ticket_types where name = 'Couple Pass');
