# Test checklist

Do these on the deployed sites, on a phone. Tick each when it behaves as described.

## 1. A stranger can place an order and read nothing else
Use a private/incognito browser that is not signed in anywhere.
- [ ] Buy a ticket end to end (details > pay > screenshot). You land on a private order page.
- [ ] Open the browser console on the public site and run:
  `await sb.from('orders').select('*')` -> permission denied
  `await sb.from('tickets').select('*')` -> permission denied
  `await sb.from('scan_log').select('*')` -> permission denied
  `await sb.from('event_settings').select('email_templates')` -> permission denied
  `await sb.storage.from('screenshots').list()` -> empty / not allowed
  `await sb.storage.from('screenshots').download('<the path you uploaded>')` -> not allowed
- [ ] `await sb.rpc('get_order',{p_token:'aaaaaaaaaaaaaaaaaaaaaaaa'})` -> null. With your real token: status shown, **no** `screenshot_path`, and `tickets` is empty while pending.
- [ ] `await sb.rpc('check_in',{p_code:'TKT-X'})` and `sb.rpc('admin_set_order_status',{p_order_id:1,p_status:'approved'})` -> permission denied.
- [ ] Without a token in the URL, another person's order cannot be opened (you cannot guess one).

## 2. Overselling is blocked
- [ ] Set a ticket type to 3 seats. Order 2, then try to order 2 more -> "Only 1 seat left".
- [ ] Order the last one -> type shows "Sold out", Buy button disappears.
- [ ] Open the buy page in two phones at once for the last seat; submit both -> exactly one succeeds.
- [ ] Reject one order in Admin -> that type shows seats again. Try "Move back to pending" when seats are gone -> refused.
- [ ] Try 4 pending orders with the same email -> the 4th is refused.
- [ ] Turn sales off, or set an end time in the past -> public page shows the closed message; a buy page opened earlier cannot submit.

## 3. Approval, email and PDF (with a Hindi name)
- [ ] Place an order with attendee name `राहुल शर्मा`. In Admin > Orders the payer name is highlighted and the screenshot opens full size.
- [ ] Approve. You get the "order received" email at submit time and the ticket email (PDF attached) on approval.
- [ ] Open the PDF: Hindi name shows joined letters correctly (not boxes, not split marks); the QR is sharp and scans to exactly the ticket code `TKT-XXXXXXXXXX`.
- [ ] Reject another order with a reason -> buyer gets the rejected email with the reason; the order page shows the reason.
- [ ] Edit email + "Save & resend" -> goes to the new address. Emails tab shows every send; unplug by giving a wrong Gmail password -> failures show with the error and Resend works after fixing it.
- [ ] Manual order (Add order) with amount 0 -> approved, ticket emailed, marked "manual".

## 4. Theme and ticket design reach everywhere
- [ ] Theme tab: change colours, roundness, font (try Hind); the preview updates live. Save, then reload the public site: new look.
- [ ] Light/Dark buttons apply a matching palette. Reset to default restores the original.
- [ ] Ticket design: change strip colour, header, footer note, toggle type/date/venue/number, add a logo. Preview updates live.
- [ ] Press "Preview as PDF": the PDF matches the preview.
- [ ] Save. Open an approved order on the public site: on-screen ticket uses the new design. Resend the ticket email: the PDF uses it too.
- [ ] Email text tab: edit the approved wording; preview updates; next email uses it.

## 4b. Group tickets, Aadhaar, instructions
- [ ] Buy 3 places: each person needs a name and an Aadhaar photo; you cannot continue without ticking "I agree" under the instructions.
- [ ] Admin > Orders shows the 3 names, each with an Aadhaar thumbnail that opens full size.
- [ ] As a stranger: `await sb.storage.from('ids').list()` -> empty / not allowed. As a scanner login: the same.
- [ ] The approved order page and PDF show ONE ticket: "ADMIT 3" and all 3 names.
- [ ] Scanning it shows "VALID - LET IN", "ADMIT 3" and the 3 names; scanning again shows "ALREADY USED". The counter goes up by 3.
- [ ] Edit the instructions in Admin > Event: the event page and buy page update.

## 5. Scanner
- [ ] Staff tab: create a scanner login. Sign in on the scanner site (camera permission allowed).
- [ ] Scan a ticket QR -> green "VALID, ENTRY OK" with name and type; counter goes up.
- [ ] Scan it again -> amber "ALREADY USED" with the time.
- [ ] Type a wrong code -> red "INVALID". Scan a ticket from a rejected/pending order -> purple "NOT VALID".
- [ ] "Undo last check-in" -> scan the same ticket again: valid again.
- [ ] Manual code entry and "Scan from photo" both work.
- [ ] Admin > Attendees shows "X of Y checked in" matching the scanner counter; Export CSV opens in Excel with the Hindi name readable.

## 6. A scanner login cannot read orders or payments
Signed in as a scanner (scanner site console):
- [ ] `await sb.from('orders').select('*')` -> permission denied (or empty)
- [ ] `await sb.from('tickets').select('*')` -> permission denied (or empty)
- [ ] `await sb.storage.from('screenshots').list()` -> empty / not allowed
- [ ] `await sb.rpc('admin_set_order_status',{p_order_id:1,p_status:'approved'})` -> FORBIDDEN
- [ ] Signing in to the **admin** site with the scanner login -> "This login is not an admin account."
- [ ] Remove the scanner login in Admin > Staff, then try a scan on the still-open scanner page -> refused immediately.
