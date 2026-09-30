// POST /api/send-ticket   Authorization: Bearer <admin JWT>
// body: { order_id, kind: 'approved' | 'rejected' | 'resent' }
//   approved -> ticket email with PDF (order must already be approved via the admin RPC)
//   rejected -> rejection email
//   resent   -> sends whichever email matches the order's current status (logged as "resent")
var L = require('./_lib');
var P = require('./_pdf');

module.exports = async function (req, res) {
  try {
    if (req.method !== 'POST') return L.json(res, 405, { error: 'POST only' });
    var admin = await L.requireAdmin(req);
    if (!admin) return L.json(res, 401, { error: 'Admin login required' });

    var b = L.body(req);
    var kind = b.kind;
    if (['approved', 'rejected', 'resent'].indexOf(kind) < 0) return L.json(res, 400, { error: 'Bad kind' });
    var order = await L.loadOrder({ id: Number(b.order_id) });
    if (!order) return L.json(res, 404, { error: 'Order not found' });
    var s = await L.loadSettings();

    var content = kind === 'resent' ? (order.status === 'approved' ? 'approved' : order.status === 'rejected' ? 'rejected' : 'received') : kind;
    if (content === 'approved' && order.status !== 'approved') return L.json(res, 409, { error: 'Order is not approved' });
    if (content === 'rejected' && order.status !== 'rejected') return L.json(res, 409, { error: 'Order is not rejected' });

    var attachments = [];
    if (content === 'approved') {
      var pdf = await P.buildPdf(order.tickets, P.ctxFor(order, s));
      attachments.push({ filename: 'Ticket-' + order.order_no + '.pdf', content: pdf, contentType: 'application/pdf' });
    }
    var r = await L.sendOrderEmail(order, s, content, kind === 'resent' ? 'resent' : kind, attachments);
    return L.json(res, r.ok ? 200 : 502, r);
  } catch (e) {
    return L.json(res, 500, { ok: false, error: (e && e.message) || String(e) });
  }
};
