// POST /api/health   Authorization: Bearer <admin JWT>   body: { send_test: true|false }
// "System check" button in Admin > Emails. Reports, step by step, whether the server is set up:
// env vars present (never their values), database access, PDF building, Gmail login, and optionally
// sends a test email to the signed-in admin.
var fs = require('fs');
var path = require('path');
var L = require('./_lib');
var P = require('./_pdf');

module.exports = async function (req, res) {
  var checks = [];
  function add(name, ok, detail) { checks.push({ name: name, ok: !!ok, detail: detail || '' }); }
  try {
    if (req.method !== 'POST') return L.json(res, 405, { error: 'POST only' });

    // env vars first: requireAdmin needs Supabase
    ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'GMAIL_USER', 'GMAIL_APP_PASSWORD', 'PUBLIC_URL'].forEach(function (k) {
      add('Env var ' + k, !!process.env[k], process.env[k] ? 'set' : 'MISSING: add it in Vercel > Settings > Environment Variables, then redeploy');
    });
    var key = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
    if (/^sb_publishable_/.test(key)) add('Service key type', false, 'SUPABASE_SERVICE_ROLE_KEY is the publishable key. Use the secret (service_role) key.');
    if (!process.env.SUPABASE_URL || !key) return L.json(res, 200, { checks: checks });

    var admin = await L.requireAdmin(req);
    if (!admin) {
      add('Admin login check', false, 'Could not verify your login with SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY. If you are signed in as admin, the key or URL is wrong.');
      return L.json(res, 200, { checks: checks });
    }
    add('Admin login check', true, admin.email);

    var s = null;
    try { s = await L.loadSettings(); add('Database (service key)', true, 'event: ' + s.name); }
    catch (e) { add('Database (service key)', false, e.message); }

    var fdir = path.join(__dirname, '..', 'fonts');
    var files = ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf', 'NotoSansDevanagari-Regular.ttf', 'NotoSansDevanagari-Bold.ttf', 'ticket-bg.jpg'];
    var missing = files.filter(function (f) { return !fs.existsSync(path.join(fdir, f)); });
    add('Ticket fonts + artwork bundled', !missing.length, missing.length ? 'missing: ' + missing.join(', ') : 'ok');

    if (s) {
      try {
        var pdf = await P.buildPdf([{ code: 'TKT-TEST234567', attendee_name: 'टेस्ट Test, Asha', count: 2 }], P.ctxFor({ type_name: 'Test', ticket_types: null }, s));
        add('Build a PDF ticket', pdf.length > 1000, Math.round(pdf.length / 1024) + ' KB');
      } catch (e) { add('Build a PDF ticket', false, e.message); }
    }

    if (process.env.GMAIL_USER && process.env.GMAIL_APP_PASSWORD) {
      try { await L.mailer().verify(); add('Gmail login', true, process.env.GMAIL_USER); }
      catch (e) { add('Gmail login', false, (e && e.message || String(e)) + ' (check GMAIL_USER and the 16-letter app password, no spaces)'); }
      if (L.body(req).send_test) {
        try {
          await L.mailer().sendMail({ from: process.env.GMAIL_USER, to: admin.email, subject: 'Ticketing system: test email', text: 'If you can read this, ticket emails can be sent.' });
          add('Test email to ' + admin.email, true, 'sent - check inbox and spam');
        } catch (e) { add('Test email to ' + admin.email, false, e.message); }
      }
    }
    return L.json(res, 200, { checks: checks });
  } catch (e) {
    add('Unexpected error', false, (e && e.message) || String(e));
    return L.json(res, 200, { checks: checks });
  }
};
