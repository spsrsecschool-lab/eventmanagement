// POST /api/preview-pdf   Authorization: Bearer <admin JWT>
// body: { name, type_name, accent, design }  -> application/pdf of one sample ticket, using the (possibly unsaved) design.
// Lets the admin check that the PDF matches the on-screen preview before saving.
var L = require('./_lib');
var P = require('./_pdf');

module.exports = async function (req, res) {
  try {
    if (req.method !== 'POST') return L.json(res, 405, { error: 'POST only' });
    var admin = await L.requireAdmin(req);
    if (!admin) return L.json(res, 401, { error: 'Admin login required' });
    var b = L.body(req);
    var s = await L.loadSettings();
    if (b.design && typeof b.design === 'object') s.ticket_design = b.design;
    var order = { type_name: String(b.type_name || 'General Entry'), ticket_types: { accent_color: b.accent || null } };
    var pdf = await P.buildPdf([{ code: 'TKT-ABCD234XYZ', attendee_name: String(b.name || 'Sample Attendee').slice(0, 80) }], P.ctxFor(order, s));
    res.statusCode = 200;
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Cache-Control', 'no-store');
    res.end(pdf);
  } catch (e) {
    L.json(res, 500, { error: (e && e.message) || String(e) });
  }
};
