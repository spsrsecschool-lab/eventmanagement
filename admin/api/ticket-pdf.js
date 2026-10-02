// GET /api/ticket-pdf?token=...   public "Download PDF" on the buyer's order page.
// The 24-char order token is the credential; only approved orders produce a PDF.
var L = require('./_lib');
var P = require('./_pdf');

// The buyer opens this URL directly (Download PDF is a plain link), so errors are a small readable page.
function page(res, code, msg) {
  var safe = String(msg).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  res.statusCode = code;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ticket</title>' +
    '<body style="font-family:system-ui,sans-serif;background:#1f0823;color:#fdf3e3;padding:40px 20px;text-align:center"><p style="font-size:18px">' + safe +
    '</p><p><a style="color:#f5cc6a" href="javascript:history.back()">Go back</a></p></body>');
}

module.exports = async function (req, res) {
  if (L.cors(req, res)) return;
  try {
    var token = String((req.query && req.query.token) || '');
    if (token.length !== 24) return page(res, 400, 'This ticket link is not valid.');
    var order = await L.loadOrder({ token: token });
    if (!order || order.status !== 'approved' || !order.ticket_code) return page(res, 404, 'This ticket is not available. It may not be approved yet.');
    var s = await L.loadSettings();
    var pdf = await P.buildPdf(P.orderTicket(order), P.ctxFor(order, s));
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', 'attachment; filename="Ticket-' + order.order_no + '.pdf"');
    res.setHeader('Cache-Control', 'no-store');
    res.end(pdf);
  } catch (e) {
    page(res, 500, 'Sorry, the ticket PDF could not be created right now. Please try again in a minute. (' + String((e && e.message) || e).slice(0, 200) + ')');
  }
};
