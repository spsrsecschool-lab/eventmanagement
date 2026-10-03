# Event ticketing (Dandiya Nights)

Buyers pick a ticket, type the name of everyone in their group, pay by UPI QR, upload a screenshot. One QR per order admits the whole group once. The organiser checks the payer name against his own payment history and approves. The buyer is emailed a PDF ticket (name + unique QR). A separate scanner app lets each ticket in once.

```
public/    buyer site (no links to admin or scanner)        -> Vercel project 1
admin/     admin site + /api serverless functions           -> Vercel project 2
scanner/   gate scanner                                     -> Vercel project 3
sql/       run in this order in the Supabase SQL editor
shared/    master copy of the on-screen ticket renderer (see "Editing the ticket" below)
tools/     check-js.sh (node --check everything), sync-ticket-svg.py
ticket.png your original artwork (the cleaned version is in */assets and admin/fonts)
```

All rules (price, overselling, who can read what) are enforced in Postgres with RLS and RPC functions, not in the pages.

## 1. Supabase

Project URL and publishable key are already filled in at the top of the three `index.html` files (`SUPABASE_URL`, `SUPABASE_KEY`). The publishable key is safe in the browser. The **secret / service-role key is only ever used in the admin project's Vercel env vars.**

In the SQL editor, run these files in order (each is safe to re-run):

| # | file | what it does |
|---|------|--------------|
| 1 | `sql/01_schema.sql` | tables, constraints, indexes |
| 2 | `sql/02_rls.sql` | locks everything down, grants only what each role needs |
| 3 | `sql/03_rpc.sql` | `create_order`, `get_order`, `check_in`, undo, admin actions |
| 4 | `sql/04_storage.sql` | `branding` (public read, admin write); `screenshots` is private: public upload only, admin read; `ids` keeps Aadhaar photos from older orders (admin read only) |
| 5 | `sql/05_seed.sql` | Dandiya Nights defaults, theme, ticket design, email wording, one **off-sale** starter ticket type |
| 6 | `sql/06_make_admin.sql` | run once after creating your admin user (below) |
| 7 | `sql/07_single_payment_qr.sql` | one payment QR for the whole event (run once if you set up before this file existed) |

**Updating an existing setup:** run the newest upgrade file once: `sql/09_upgrade_v3.sql` (couple pass, one payment QR per amount, UPI ID, dandiya rental). Earlier upgrades (`08`) must already have been run.

**Live admin orders:** run `sql/10_realtime.sql` once so the admin Orders tab updates instantly (green "Live" badge). Without it the tab still checks for new orders every 20 seconds ("Auto-refresh" badge).

**Venue map:** run `sql/11_venue_map.sql` once, then in Admin → Event paste the venue's Google Maps link (or type the address). Approved buyers see a map with a Get directions button on their pass page, and the ticket email gets a venue card with the same button. Use `{map}` in an email template to place the link yourself.

**No Aadhaar uploads:** run `sql/12_no_aadhaar.sql` once. Buyers then only type each person's name; the Aadhaar photo step is gone from booking, admin and scanner.

**Staff booking:** run `sql/13_staff_booking.sql` once. In Admin → Event turn on **Staff booking**, copy the staff link and add it as a button on your staff portal. Staff get the discount (default 20%) on every pass and can book for at most 2 people in total (matched by mobile number or email; rejected orders don't count). Upload a staff payment QR for each amount shown. Staff orders appear in Orders with a **staff** tag and a **Staff** filter. **Make a new link** stops the old one working.

Running 01 to 05 again also works; they are safe to re-run.

**Create the first admin:** Supabase > Authentication > Users > Add user (email + password, tick Auto Confirm). Put that email into `06_make_admin.sql` and run it (should print `UPDATE 1`). Sign in on the admin site. Scanner logins are created from the admin site (Staff tab), never by hand.

## 2. Gmail

Use a dedicated Gmail account. Turn on 2-Step Verification, then create an **App password** (Google Account > Security > App passwords). Free Gmail allows about 500 recipients/day. Every send is logged (Admin > Emails) with the error if it failed, and there is a Resend button.

## 3. Deploy three Vercel projects (same GitHub repo)

Create three projects from this repo; for each set **Root Directory** and leave the framework as "Other" (no build command).

| project | Root Directory | env vars |
|---|---|---|
| public | `public` | none |
| admin | `admin` | see below |
| scanner | `scanner` | none |

Admin project env vars (Settings > Environment Variables):

| name | value |
|---|---|
| `SUPABASE_URL` | `https://iuvxavsuoiekrjnylxpy.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase > Project Settings > API keys > **secret / service_role** key |
| `GMAIL_USER` | the dedicated Gmail address |
| `GMAIL_APP_PASSWORD` | the 16-character app password |
| `PUBLIC_URL` | the public site URL, e.g. `https://my-tickets.vercel.app` (no trailing slash). Used for order links in emails and to allow only that site to call the public endpoints |

Then edit one line in `public/index.html`: `API_BASE` = the **admin** project URL (the public site only calls its `/api/order-received` and `/api/ticket-pdf`). Optionally set `SCANNER_URL` in `admin/index.html` so the Staff tab shows the link. Commit and push; Vercel redeploys.

Functions (all in `admin/api/`):
`send-ticket` (admin JWT) ticket / rejected / resend emails with PDF · `preview-pdf` (admin JWT) sample PDF for the design tab · `staff` (admin JWT) create/remove scanner logins · `health` (admin JWT) the System check · `order-received` (public, rate limited) the "we got your order" email · `ticket-pdf` (public, needs the private order token) the Download PDF button.

## 4. First-time setup in the admin site
1. **Event**: check name/date/venue, payment instructions, then tick "Ticket sales are open".
2. **Event**: upload the UPI **Payment QR** (one QR for all ticket types).
3. **Ticket types**: edit *General Entry* (price, seats), turn it on.
4. **Staff**: create scanner logins for the gate volunteers.
5. Place a test order on the public site, approve it, check the email.

## Notes
- The ticket artwork (`assets/ticket-bg.jpg`) is your Dandiya Nights template with the `000000` placeholder and the "SCAN QR CODE" frame text removed. The title, date and venue printed **on the artwork** are part of the image; the strip under it (name, type, date, venue, code, footer) is driven by the admin settings. For a different event, replace the image in `public/assets`, `admin/assets` and `admin/fonts` (same name, same proportions).
- **Editing the ticket look:** the on-screen ticket and the PDF use the same 1000-unit layout. The screen version is in `shared/ticket-svg.js` (run `python3 tools/sync-ticket-svg.py` to copy it into the pages); the PDF version is `drawTicket()` in `admin/api/_pdf.js`. Change both together.
- PDFs embed Noto Sans + Noto Sans Devanagari (`admin/fonts`), so Hindi names render with correct conjuncts.
- Before pushing JS changes: `tools/check-js.sh`.
- Keep the camera working: the scanner must be served over HTTPS (Vercel does this).

## If emails or PDF downloads do not work
Admin > **Emails** > **Run system check**. It checks each part separately and shows the exact problem:
the env vars, whether the service key is the secret one, database access, building a PDF, and the Gmail login.
**Check + send me a test email** also sends a test message to your admin address.
After changing any env var in Vercel, **redeploy** the admin project (Deployments > ... > Redeploy).
