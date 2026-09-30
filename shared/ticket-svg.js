// MASTER COPY of the on-screen ticket renderer. It is inlined into public/index.html and admin/index.html
// between the "<ticket-svg>" markers by tools/sync-ticket-svg.py (edit here, then run that script).
// Keep the geometry identical to drawTicket() in admin/api/_pdf.js so screen and PDF look the same.
var TK_W = 1000, TK_ART_H = 780 / 2016 * 1000, TK_STRIP_H = 170, TK_H = TK_ART_H + TK_STRIP_H;
function tkEsc(t) { return String(t == null ? '' : t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
function tkHex(c, d) { return /^#[0-9a-fA-F]{6}$/.test(c || '') ? c : d; }
function tkFit(text, size, maxW, bold, min) {
  var k = bold ? 0.66 : 0.6, s = size;
  while (s > (min || 14) && text.length * s * k > maxW) s -= 1;
  if (text.length * s * k > maxW) text = text.slice(0, Math.max(1, Math.floor(maxW / (s * k)) - 1)) + '…';
  return { text: text, size: s };
}
// t: {code, attendee_name}; c: {s: event settings, typeName, accent, logoUrl, bgUrl}
function renderTicketSVG(t, c) {
  var s = c.s || {}, d = s.ticket_design || {};
  var stripBg = tkHex(d.strip_bg, '#2b0a30'), stripText = tkHex(d.strip_text, '#fff4e0');
  var accent = tkHex(c.accent, tkHex(d.accent, '#f5cc6a'));
  var numColor = tkHex(d.number_color, '#f9d77a'), qrColor = tkHex(d.qr_color, '#2b0a30');
  var FF = "font-family=\"'Noto Sans','Noto Sans Devanagari',sans-serif\"";
  var qr = qrcode(0, 'M'); qr.addData(t.code); qr.make();
  var n = qr.getModuleCount(), cell = 100 / n, qp = '', r, q;
  for (r = 0; r < n; r++) for (q = 0; q < n; q++) {
    if (qr.isDark(r, q)) qp += 'M' + (57.1 + q * cell).toFixed(2) + ' ' + (162.3 + r * cell).toFixed(2) + 'h' + (cell + 0.05).toFixed(2) + 'v' + (cell + 0.05).toFixed(2) + 'h-' + (cell + 0.05).toFixed(2) + 'z';
  }
  var y0 = TK_ART_H, tx = 36, o = '';
  o += '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + TK_W + ' ' + TK_H.toFixed(2) + '" width="100%" style="display:block" role="img" aria-label="Ticket ' + tkEsc(t.code) + '">';
  o += '<image href="' + tkEsc(c.bgUrl) + '" x="0" y="0" width="' + TK_W + '" height="' + TK_ART_H.toFixed(2) + '" preserveAspectRatio="none"/>';
  if (d.show_number !== false) {
    o += '<text x="106.6" y="95" text-anchor="middle" font-size="19" letter-spacing="2.5" fill="' + numColor + '" ' + FF + '>' + tkEsc(t.code.replace(/^TKT-/, '')) + '</text>';
  }
  o += '<path d="' + qp + '" fill="' + qrColor + '"/>';
  o += '<rect x="0" y="' + y0.toFixed(2) + '" width="' + TK_W + '" height="' + TK_STRIP_H + '" fill="' + stripBg + '"/>';
  o += '<rect x="0" y="' + y0.toFixed(2) + '" width="' + TK_W + '" height="5" fill="' + accent + '"/>';
  if (d.show_logo && c.logoUrl) {
    o += '<image href="' + tkEsc(c.logoUrl) + '" x="36" y="' + (y0 + 37).toFixed(2) + '" width="96" height="96" preserveAspectRatio="xMidYMid meet"/>';
    tx = 154;
  }
  var maxW = 964 - tx, f;
  if (d.header_text) {
    f = tkFit(d.header_text, 15, maxW, false, 11);
    o += '<text x="' + tx + '" y="' + (y0 + 38).toFixed(2) + '" font-size="' + f.size + '" letter-spacing="3" fill="' + accent + '" ' + FF + '>' + tkEsc(f.text) + '</text>';
  }
  f = tkFit(t.attendee_name || '', 40, maxW, true, 20);
  o += '<text x="' + tx + '" y="' + (y0 + 88).toFixed(2) + '" font-size="' + f.size + '" font-weight="700" fill="' + stripText + '" ' + FF + '>' + tkEsc(f.text) + '</text>';
  var bits = [];
  if (d.show_type !== false && c.typeName) bits.push(c.typeName);
  if (d.show_date !== false && s.date_text) bits.push(s.date_text);
  if (d.show_venue !== false && s.venue) bits.push(s.venue);
  if (bits.length) {
    f = tkFit(bits.join('  •  '), 20, maxW, false, 12);
    o += '<text x="' + tx + '" y="' + (y0 + 122).toFixed(2) + '" font-size="' + f.size + '" fill="' + stripText + '" fill-opacity="0.85" xml:space="preserve" ' + FF + '>' + tkEsc(f.text) + '</text>';
  }
  var codeW = d.show_number !== false ? 190 : 0;
  if (d.footer_note) {
    f = tkFit(d.footer_note, 17, maxW - codeW, false, 11);
    o += '<text x="' + tx + '" y="' + (y0 + 154).toFixed(2) + '" font-size="' + f.size + '" fill="' + stripText + '" fill-opacity="0.7" ' + FF + '>' + tkEsc(f.text) + '</text>';
  }
  if (d.show_number !== false) {
    o += '<text x="964" y="' + (y0 + 154).toFixed(2) + '" text-anchor="end" font-size="16" letter-spacing="1" fill="' + stripText + '" fill-opacity="0.7" ' + FF + '>' + tkEsc(t.code) + '</text>';
  }
  return o + '</svg>';
}
