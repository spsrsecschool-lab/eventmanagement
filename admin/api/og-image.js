// GET /api/og-image   the link-preview image (WhatsApp, Instagram, Facebook...) for the buyer site.
// Serves the image uploaded in Admin > Event > Link preview image, else the default from the public site.
// Public on purpose: it is the same picture anyone sees under a shared link.
var L = require('./_lib');

function send(res, buf, type) {
  res.statusCode = 200;
  res.setHeader('Content-Type', type || 'image/jpeg');
  res.setHeader('Cache-Control', 'public, max-age=600, s-maxage=600');   // a new upload shows within ~10 minutes
  res.end(buf);
}

module.exports = async function (req, res) {
  if (L.cors(req, res)) return;
  try {
    var s = await L.loadSettings();
    if (s.og_image_path) {
      var d = await L.db().storage.from('branding').download(s.og_image_path);
      if (!d.error && d.data) return send(res, Buffer.from(await d.data.arrayBuffer()), d.data.type || 'image/jpeg');
    }
  } catch (e) { /* fall back to the default image */ }
  try {
    var r = await fetch(L.publicUrl() + '/assets/og-image.jpg');
    if (r.ok) return send(res, Buffer.from(await r.arrayBuffer()), 'image/jpeg');
  } catch (e) { /* nothing else to try */ }
  res.statusCode = 404; res.setHeader('Cache-Control', 'no-store'); res.end('No preview image');
};
