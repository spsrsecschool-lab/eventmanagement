// Ticket PDF. The drawing code mirrors renderTicketSVG() in public/index.html and admin/index.html:
// same 1000-unit-wide artboard, same coordinates, same text-fit rule, so screen and PDF match.
var fs = require('fs');
var path = require('path');
var PDFDocument = require('pdfkit');
var QRCode = require('qrcode');

var W = 1000, ART_H = 780 / 2016 * 1000, STRIP_H = 170, H = ART_H + STRIP_H;
var PAGE_W = 842;
var FONT_DIR = path.join(__dirname, '..', 'fonts');
var BG = null;
function bg() { if (!BG) BG = fs.readFileSync(path.join(FONT_DIR, 'ticket-bg.jpg')); return BG; }

var DEVA = /[ऀ-ॿ‌‍]+(?:[ ]+[ऀ-ॿ‌‍]+)*/g;
function runs(text) {
  var out = [], last = 0, m;
  DEVA.lastIndex = 0;
  while ((m = DEVA.exec(text))) {
    if (m.index > last) out.push({ t: text.slice(last, m.index), deva: false });
    out.push({ t: m[0], deva: true });
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push({ t: text.slice(last), deva: false });
  return out;
}

// Same rule as the on-screen SVG: shrink to fit, then ellipsis.
function fit(text, size, maxW, bold, min) {
  var k = bold ? 0.66 : 0.6;
  var s = size;
  while (s > (min || 14) && text.length * s * k > maxW) s -= 1;
  if (text.length * s * k > maxW) text = text.slice(0, Math.max(1, Math.floor(maxW / (s * k)) - 1)) + '…';
  return { text: text, size: s };
}

function hex(c, d) { return /^#[0-9a-fA-F]{6}$/.test(c || '') ? c : d; }

// Draws text with a baseline at y; handles Hindi + Latin runs in one string. anchor: start | middle | end
function text(doc, str, x, y, o) {
  var rs = runs(str), total = 0, i;
  var ls = o.spacing || 0;
  rs.forEach(function (r) {
    r.font = (r.deva ? 'deva' : 'latin') + (o.bold ? 'B' : 'R');
    doc.font(r.font).fontSize(o.size);
    r.w = doc.widthOfString(r.t) + ls * r.t.length;
    total += r.w;
  });
  var cx = o.anchor === 'middle' ? x - total / 2 : o.anchor === 'end' ? x - total : x;
  doc.fillColor(o.color).fillOpacity(o.opacity == null ? 1 : o.opacity);
  rs.forEach(function (r) {
    doc.font(r.font).fontSize(o.size);
    var asc = doc._font.ascender / 1000 * o.size;
    doc.text(r.t, cx, y - asc, { lineBreak: false, characterSpacing: ls });
    cx += r.w;
  });
  doc.fillOpacity(1);
}

async function logoBuffer(url) {
  if (!url) return null;
  try {
    var r = await fetch(url);
    if (!r.ok) return null;
    var b = Buffer.from(await r.arrayBuffer());
    var isPng = b[0] === 0x89 && b[1] === 0x50, isJpg = b[0] === 0xff && b[1] === 0xd8;
    return isPng || isJpg ? b : null;
  } catch (e) { return null; }
}

// ticket: {code, attendee_name}; ctx: {settings, typeName, accent}
function drawTicket(doc, ticket, ctx, qr, logo) {
  var s = ctx.settings, d = s.ticket_design || {};
  var stripBg = hex(d.strip_bg, '#2b0a30'), stripText = hex(d.strip_text, '#fff4e0');
  var accent = hex(ctx.accent, hex(d.accent, '#f5cc6a'));
  var numColor = hex(d.number_color, '#f9d77a'), qrColor = hex(d.qr_color, '#2b0a30');

  doc.save().scale(PAGE_W / W);
  doc.image(bg(), 0, 0, { width: W, height: ART_H });

  // stub: ticket number + QR (QR carries only the ticket code)
  if (d.show_number !== false) {
    text(doc, ticket.code.replace(/^TKT-/, ''), 106.6, 95, { size: 19, bold: false, color: numColor, anchor: 'middle', spacing: 2.5 });
  }
  var q = 100, qx = 57.1, qy = 162.3, n = qr.size, cell = q / n;
  doc.fillColor(qrColor);
  for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) {
    if (qr.data[r * n + c]) doc.rect(qx + c * cell, qy + r * cell, cell + 0.05, cell + 0.05).fill();
  }

  // strip
  doc.rect(0, ART_H, W, STRIP_H).fill(stripBg);
  doc.rect(0, ART_H, W, 5).fill(accent);
  var tx = 36, y0 = ART_H;
  if (d.show_logo && logo) {
    try { doc.image(logo, 36, y0 + 37, { fit: [96, 96], align: 'center', valign: 'center' }); tx = 154; } catch (e) { /* bad logo: skip */ }
  }
  var maxW = 964 - tx;
  if (d.header_text) {
    var h1 = fit(d.header_text, 15, maxW, false, 11);
    text(doc, h1.text, tx, y0 + 38, { size: h1.size, color: accent, spacing: 3 });
  }
  var nm = fit(ticket.attendee_name, 40, maxW, true, 20);
  text(doc, nm.text, tx, y0 + 88, { size: nm.size, bold: true, color: stripText });

  var bits = [];
  if (d.show_type !== false) bits.push(ctx.typeName);
  if (d.show_date !== false && s.date_text) bits.push(s.date_text);
  if (d.show_venue !== false && s.venue) bits.push(s.venue);
  if (bits.length) {
    var dl = fit(bits.join('  •  '), 20, maxW, false, 12);
    text(doc, dl.text, tx, y0 + 122, { size: dl.size, color: stripText, opacity: 0.85 });
  }
  var codeW = d.show_number !== false ? 190 : 0;
  if (d.footer_note) {
    var fn = fit(d.footer_note, 17, maxW - codeW, false, 11);
    text(doc, fn.text, tx, y0 + 154, { size: fn.size, color: stripText, opacity: 0.7 });
  }
  if (d.show_number !== false) {
    text(doc, ticket.code, 964, y0 + 154, { size: 16, color: stripText, opacity: 0.7, anchor: 'end', spacing: 1 });
  }
  doc.restore();
}

// Returns a Buffer with one page per ticket.
async function buildPdf(tickets, ctx) {
  var logo = (ctx.settings.ticket_design || {}).show_logo ? await logoBuffer(ctx.logoUrl) : null;
  var doc = new PDFDocument({ autoFirstPage: false, margin: 0, info: { Title: ctx.settings.name + ' ticket', Author: ctx.settings.name } });
  doc.registerFont('latinR', path.join(FONT_DIR, 'NotoSans-Regular.ttf'));
  doc.registerFont('latinB', path.join(FONT_DIR, 'NotoSans-Bold.ttf'));
  doc.registerFont('devaR', path.join(FONT_DIR, 'NotoSansDevanagari-Regular.ttf'));
  doc.registerFont('devaB', path.join(FONT_DIR, 'NotoSansDevanagari-Bold.ttf'));
  var chunks = [];
  doc.on('data', function (c) { chunks.push(c); });
  var done = new Promise(function (res, rej) { doc.on('end', res); doc.on('error', rej); });
  for (var i = 0; i < tickets.length; i++) {
    var qr = QRCode.create(tickets[i].code, { errorCorrectionLevel: 'M' }).modules;
    doc.addPage({ size: [PAGE_W, PAGE_W * H / W], margin: 0 });
    drawTicket(doc, tickets[i], ctx, qr, logo);
  }
  doc.end();
  await done;
  return Buffer.concat(chunks);
}

function ctxFor(order, settings) {
  var url = settings.logo_path && process.env.SUPABASE_URL
    ? process.env.SUPABASE_URL.replace(/\/+$/, '') + '/storage/v1/object/public/branding/' + settings.logo_path : null;
  var d = settings.ticket_design || {};
  var own = d.logo_path ? process.env.SUPABASE_URL.replace(/\/+$/, '') + '/storage/v1/object/public/branding/' + d.logo_path : null;
  return { settings: settings, typeName: order.type_name,
           accent: order.ticket_types && order.ticket_types.accent_color, logoUrl: own || url };
}

module.exports = { buildPdf: buildPdf, ctxFor: ctxFor };
