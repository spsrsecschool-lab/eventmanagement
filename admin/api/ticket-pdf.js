// GET /api/ticket-pdf?token=...   public "Download PDF" on the buyer's order page.
// The 24-char order token is the credential; only approved orders produce a PDF.
var L = require('./_lib');
var P = require('./_pdf');

module.exports = async function (req, res) {
  if (L.cors(req, res)) return;
  try {
    var token = String((req.query && req.query.token) || '');
    if (token.length !== 24) return L.json(res, 400, { error: 'Bad token' });
    var order = await L.loadOrder({ token: token });
    if (!order || order.status !== 'approved') return L.json(res, 404, { error: 'Not available' });
    var s = await L.loadSettings();
    var pdf = await P.buildPdf(order.tickets, P.ctxFor(order, s));
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', 'attachment; filename="Ticket-' + order.order_no + '.pdf"');
    res.setHeader('Cache-Control', 'no-store');
    res.end(pdf);
  } catch (e) {
    L.json(res, 500, { error: 'Could not build ticket: ' + String((e && e.message) || e).slice(0, 200) });
  }
};
