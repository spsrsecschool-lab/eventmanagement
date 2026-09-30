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

// CORS for the endpoints the public site calls (order-received, ticket-pdf)
function cors(req, res) {
  var o = publicUrl();
  res.setHeader('Access-Control-Allow-Origin', o || '*');
  res.setHeader('Vary', 'Origin');
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
  var q = db().from('orders').select('*, tickets(id, code, attendee_name), ticket_types(accent_color)');
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
function htmlBody(text, s) {
  var th = s.theme || {};
  var accent = th.primary || '#c2185b';
  var linked = esc(text).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:' + accent + '">$1</a>').replace(/\n/g, '<br>');
  return '<div style="background:#f4f1f5;padding:18px 10px;font-family:Arial,Helvetica,sans-serif">' +
    '<div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #e6dfe8">' +
    '<div style="background:' + (th.background || '#2b0a30') + ';color:' + (th.accent || '#f5cc6a') + ';padding:16px 20px;font-size:18px;font-weight:bold">' + esc(s.name) + '</div>' +
    '<div style="padding:20px;color:#222;font-size:15px;line-height:1.55">' + linked + '</div></div></div>';
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
      to: order.email, subject: fill(t.subject, v), text: text, html: htmlBody(text, s),
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
  loadOrder: loadOrder, sendOrderEmail: sendOrderEmail, publicUrl: publicUrl, fill: fill, varsFor: varsFor, template: template };
