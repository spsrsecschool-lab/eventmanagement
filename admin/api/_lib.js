// Shared helpers for the serverless functions. Files starting with "_" are not routed by Vercel.
// The service-role key is used ONLY here (server side). Never ship it to a browser.
var createClient = require('@supabase/supabase-js').createClient;
var nodemailer = require('nodemailer');

var sb = null;
function db() {
  if (!sb) {
    if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set');
    sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  }
  return sb;
}

function publicUrl() { return (process.env.PUBLIC_URL || '').replace(/\/+$/, ''); }

// CORS for the endpoints the public site calls (order-received, ticket-pdf).
// Open to any origin on purpose: no cookies are involved, and the real protection is server side
// (unguessable order token, pending/age/rate limits). A strict origin broke on small PUBLIC_URL typos.
function cors(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return true; }
  return false;
}

function json(res, code, obj) {
  res.statusCode = code;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(obj));
}

function body(req) {
  var b = req.body;
  if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } }
  return b && typeof b === 'object' ? b : {};
}

// Verifies the caller's Supabase JWT and that they are an (un-banned) admin.
async function requireAdmin(req) {
  var h = req.headers.authorization || '';
  var m = /^Bearer (.+)$/i.exec(h);
  if (!m) return null;
  var r = await db().auth.getUser(m[1]);
  var u = r && r.data && r.data.user;
  if (!u || r.error) return null;
  if ((u.app_metadata || {}).role !== 'admin') return null;
  if (u.banned_until && new Date(u.banned_until) > new Date()) return null;
  return u;
}

// ---- data loading ----
async function loadSettings() {
  var r = await db().from('event_settings').select('*').eq('id', 1).single();
  if (r.error) throw new Error('settings: ' + r.error.message);
  return r.data;
}
async function loadOrder(filter) {
  var q = db().from('orders').select('*, tickets(id, attendee_name), ticket_types(accent_color)');
  var r = await q.match(filter).maybeSingle();
  if (r.error) throw new Error('order: ' + r.error.message);
  if (r.data && r.data.tickets) r.data.tickets.sort(function (a, b) { return a.id - b.id; });
  return r.data;
}

// ---- templates ----
var DEFAULT_TEMPLATES = {
  received: { subject: 'We received your order {order_no} - {event}', body: 'Hi {name},\n\nWe received your order {order_no}. We are verifying your payment and will email your ticket once it is approved.\n\nTrack your order: {link}' },
  approved: { subject: 'Your ticket for {event} ({order_no})', body: 'Hi {name},\n\nYour payment is verified. Your ticket(s) are attached as a PDF.\n\nBackup link: {link}' },
  rejected: { subject: 'Update on your order {order_no} - {event}', body: 'Hi {name},\n\nWe could not verify the payment for order {order_no}.\nReason: {reason}\n\nOrder link: {link}' }
};
function fill(str, vars) {
  return String(str || '').replace(/\{(\w+)\}/g, function (m, k) { return vars[k] != null ? String(vars[k]) : m; });
}
function varsFor(order, s) {
  return {
    name: order.buyer_name, order_no: order.order_no, event: s.name, date: s.date_text, venue: s.venue,
    link: publicUrl() + '/#/order/' + order.token, reason: order.reject_reason || 'Not specified',
    type: order.type_name, qty: order.qty, amount: order.amount,
    contact_phone: s.contact_phone || '', contact_email: s.contact_email || ''
  };
}
function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
// Themed HTML email (same art direction as the website): poster header, scalloped edge, headline per email
// type, the admin's editable text in a card, booking summary, gold button, tile-strip footer.
// Table layout + inline styles only (what email apps support). Dark throughout so Gmail dark mode leaves it alone.
function htmlBody(text, s, ctx) {
  ctx = ctx || {};
  var base = publicUrl(), img = function (f) { return base ? base + '/assets/' + f : ''; };
  var o = ctx.order || {}, kind = ctx.kind || 'received', link = ctx.link || base;
  var GOLD = '#f4b63f', CREAM = '#fbeed6', SOFT = '#ecd2e4', NIGHT = '#2a0430', POSTER = '#38003a', CARD = '#3b0a44';
  var SERIF = "Georgia,'Times New Roman',serif", SANS = 'Arial,Helvetica,sans-serif';
  var HEAD = { received: ['Booking received', 'We are verifying your payment'], approved: ['You’re in!', 'Your pass is attached to this email'],
               rejected: ['Payment not verified', 'Here is what happened'] }[kind] || [s.name, ''];
  var CTA = { received: 'Track your booking', approved: 'View your pass', rejected: 'View your booking' }[kind] || 'Open';
  var dia = '<div style="font-family:' + SANS + ';color:' + GOLD + ';font-size:11px;letter-spacing:8px;line-height:1">&#9670;&#9670;&#9670;</div>';
  var body = esc(text).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:' + GOLD + ';word-break:break-all">$1</a>').replace(/\n/g, '<br>');
  var people = (o.tickets || []).length;
  var rows = [['Booking', o.order_no], ['Pass', (o.qty || '') + ' × ' + (o.type_name || '')],
    people ? ['Admits', people + (people === 1 ? ' person' : ' people')] : null,
    ['Amount', '₹' + Number(o.amount || 0).toLocaleString('en-IN')],
    s.date_text ? ['When', s.date_text] : null, s.venue ? ['Where', s.venue] : null].filter(function (r) { return r && r[1]; });
  var summary = rows.map(function (r) {
    return '<tr><td style="padding:9px 0;border-top:1px dashed rgba(244,182,63,.35);font-family:' + SANS + ';font-size:11px;letter-spacing:2px;text-transform:uppercase;color:' + GOLD + ';white-space:nowrap;vertical-align:top">' + esc(r[0]) + '</td>' +
      '<td align="right" style="padding:9px 0 9px 14px;border-top:1px dashed rgba(244,182,63,.35);font-family:' + SANS + ';font-size:15px;font-weight:bold;color:' + CREAM + '">' + esc(r[1]) + '</td></tr>';
  }).join('');
  var contact = [s.contact_phone, s.contact_email].filter(Boolean).map(esc).join(' &middot; ');
  var html = '<div style="margin:0;padding:0;background:' + NIGHT + '">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="' + NIGHT + '" style="background:' + NIGHT + '"><tr><td align="center">' +
    '<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px">' +
      // poster header
      '<tr><td bgcolor="' + POSTER + '" align="center" style="background:' + POSTER + ';padding:26px 20px 10px">' +
        (base ? '<img src="' + img('hero-poster.jpg') + '" width="300" alt="' + esc(s.name) + '" style="display:block;width:300px;max-width:82%;height:auto;margin:0 auto;border:2px solid ' + GOLD + ';border-radius:14px">'
              : '<div style="font-family:' + SERIF + ';font-size:34px;font-weight:bold;color:' + CREAM + '">' + esc(s.name) + '</div>') +
        '<div style="font-family:' + SANS + ';color:' + GOLD + ';font-size:12px;letter-spacing:2px;text-transform:uppercase;padding-top:16px;line-height:1.6">' +
          esc([s.date_text, s.venue].filter(Boolean).join('  ·  ')) + '</div></td></tr>' +
      (base ? '<tr><td bgcolor="' + NIGHT + '" style="line-height:0;font-size:0"><img src="' + img('email-edge.png') + '" width="600" alt="" style="display:block;width:100%;height:auto;border:0"></td></tr>' : '') +
      // headline
      '<tr><td align="center" bgcolor="' + NIGHT + '" style="padding:14px 20px 4px">' + dia +
        '<div style="font-family:' + SERIF + ';font-style:italic;font-weight:bold;font-size:36px;line-height:1.15;color:' + GOLD + ';padding-top:12px">' + esc(HEAD[0]) + '</div>' +
        (HEAD[1] ? '<div style="font-family:' + SANS + ';font-size:15px;color:' + SOFT + ';padding-top:6px">' + esc(HEAD[1]) + '</div>' : '') + '</td></tr>' +
      // editable text
      '<tr><td style="padding:18px 18px 6px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="' + CARD + '" style="background:' + CARD + ';border:1px solid rgba(244,182,63,.45);border-radius:14px">' +
        '<tr><td style="padding:22px 22px;font-family:' + SANS + ';font-size:16px;line-height:1.65;color:' + CREAM + '">' + body + '</td></tr></table></td></tr>' +
      // summary
      (rows.length ? '<tr><td style="padding:14px 26px 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">' + summary + '</table></td></tr>' : '') +
      // button
      (link ? '<tr><td align="center" style="padding:26px 20px 30px"><a href="' + esc(link) + '" style="display:inline-block;background:' + GOLD + ';color:' + NIGHT + ';font-family:' + SANS +
        ';font-weight:bold;font-size:15px;letter-spacing:1px;text-transform:uppercase;text-decoration:none;padding:15px 34px;border-radius:8px">' + esc(CTA) + ' &rarr;</a></td></tr>' : '') +
      // footer
      (base ? '<tr><td bgcolor="' + NIGHT + '" style="line-height:0;font-size:0"><img src="' + img('email-edge-up.png') + '" width="600" alt="" style="display:block;width:100%;height:auto;border:0"></td></tr>' : '') +
      '<tr><td bgcolor="' + POSTER + '" align="center" style="background:' + POSTER + ';padding:14px 20px 20px;font-family:' + SANS + ';font-size:13px;line-height:1.7;color:' + SOFT + '">' + dia +
        '<div style="font-family:' + SERIF + ';font-size:20px;font-weight:bold;color:' + CREAM + ';padding-top:10px">' + esc(s.name) + '</div>' +
        esc([s.date_text, s.venue].filter(Boolean).join(' · ')) + (contact ? '<br>Questions? ' + contact : '') + '</td></tr>' +
      (base ? '<tr><td bgcolor="' + POSTER + '" style="line-height:0;font-size:0"><img src="' + img('email-tiles.png') + '" width="600" alt="" style="display:block;width:100%;height:auto;border:0"></td></tr>' : '') +
    '</table></td></tr></table></div>';
  return asciiSafe(html);
}
// Write every non-ASCII character (rupee sign, quotes, Hindi names, ...) as an HTML entity so no email app garbles it.
function asciiSafe(str) {
  var out = '';
  for (var ch of str) { var c = ch.codePointAt(0); out += c > 127 ? '&#' + c + ';' : ch; }
  return out;
}
function template(s, kind) {
  var t = (s.email_templates || {})[kind] || {};
  var d = DEFAULT_TEMPLATES[kind];
  return { subject: t.subject || d.subject, body: t.body || d.body };
}

// ---- sending + logging ----
var transport = null;
function mailer() {
  if (!transport) {
    if (!process.env.GMAIL_USER || !process.env.GMAIL_APP_PASSWORD) throw new Error('GMAIL_USER / GMAIL_APP_PASSWORD not set');
    transport = nodemailer.createTransport({ service: 'gmail', auth: { user: process.env.GMAIL_USER, pass: process.env.GMAIL_APP_PASSWORD } });
  }
  return transport;
}
async function logEmail(orderId, kind, to, status, error) {
  try { await db().from('email_log').insert({ order_id: orderId, kind: kind, to_email: to, status: status, error: error ? String(error).slice(0, 500) : null }); } catch (e) { /* never block on logging */ }
}
// kind: received | approved | rejected | resent (resent = logged as "resent", content depends on order status)
async function sendOrderEmail(order, s, contentKind, logKind, attachments) {
  var t = template(s, contentKind);
  var v = varsFor(order, s);
  var text = fill(t.body, v);
  try {
    await mailer().sendMail({
      from: '"' + String(s.name).replace(/"/g, '') + '" <' + process.env.GMAIL_USER + '>',
      to: order.email, subject: fill(t.subject, v), text: text, html: htmlBody(text, s, { kind: contentKind, order: order, link: v.link }),
      attachments: attachments || []
    });
    await logEmail(order.id, logKind, order.email, 'sent', null);
    return { ok: true };
  } catch (e) {
    await logEmail(order.id, logKind, order.email, 'failed', e && e.message || e);
    return { ok: false, error: (e && e.message) || String(e) };
  }
}

module.exports = { db: db, cors: cors, json: json, body: body, requireAdmin: requireAdmin, loadSettings: loadSettings,
  loadOrder: loadOrder, sendOrderEmail: sendOrderEmail, mailer: mailer, htmlBody: htmlBody, publicUrl: publicUrl, fill: fill, varsFor: varsFor, template: template };
