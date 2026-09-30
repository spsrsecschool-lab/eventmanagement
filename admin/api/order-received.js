// POST /api/order-received   body: { token }   (called by the public site right after an order is placed)
// No login, so it is tightly limited: only a fresh, still-pending order; at most 2 attempts per order;
// at most 5 "received" emails per address per hour. The buyer cannot choose the recipient or the content.
var L = require('./_lib');

module.exports = async function (req, res) {
  if (L.cors(req, res)) return;
  try {
    if (req.method !== 'POST') return L.json(res, 405, { error: 'POST only' });
    var token = String(L.body(req).token || '');
    if (token.length !== 24) return L.json(res, 400, { error: 'Bad token' });

    var order = await L.loadOrder({ token: token });
    if (!order) return L.json(res, 404, { error: 'Not found' });
    if (order.status !== 'pending' || order.source !== 'online') return L.json(res, 409, { error: 'Not applicable' });
    if (Date.now() - new Date(order.created_at).getTime() > 30 * 60 * 1000) return L.json(res, 409, { error: 'Too late' });

    var db = L.db();
    var prior = await db.from('email_log').select('status').eq('order_id', order.id).eq('kind', 'received');
    var rows = prior.data || [];
    if (rows.some(function (r) { return r.status === 'sent'; }) || rows.length >= 2) return L.json(res, 200, { ok: true, skipped: true });

    var hourAgo = new Date(Date.now() - 3600 * 1000).toISOString();
    var recent = await db.from('email_log').select('id', { count: 'exact', head: true })
      .eq('kind', 'received').eq('to_email', order.email).gte('created_at', hourAgo);
    if ((recent.count || 0) >= 5) return L.json(res, 429, { error: 'Rate limit' });

    var s = await L.loadSettings();
    var r = await L.sendOrderEmail(order, s, 'received', 'received', []);
    return L.json(res, 200, { ok: r.ok });   // do not leak SMTP errors to the public; admin sees them in the log
  } catch (e) {
    return L.json(res, 500, { ok: false });
  }
};
