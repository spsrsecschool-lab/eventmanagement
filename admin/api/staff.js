// Scanner logins. Admin only (verified from the caller's JWT); uses the service-role key.
//   GET     -> list scanner users
//   POST    -> { name, email, password } create
//   DELETE  -> { id } remove (scanner accounts only)
var L = require('./_lib');

module.exports = async function (req, res) {
  try {
    var admin = await L.requireAdmin(req);
    if (!admin) return L.json(res, 401, { error: 'Admin login required' });
    var auth = L.db().auth.admin;

    if (req.method === 'GET') {
      var r = await auth.listUsers({ page: 1, perPage: 200 });
      if (r.error) return L.json(res, 500, { error: r.error.message });
      var list = r.data.users.filter(function (u) { return (u.app_metadata || {}).role === 'scanner'; })
        .map(function (u) { return { id: u.id, email: u.email, name: (u.user_metadata || {}).name || '', created_at: u.created_at, last_sign_in_at: u.last_sign_in_at }; });
      return L.json(res, 200, { staff: list });
    }

    var b = L.body(req);
    if (req.method === 'POST') {
      var email = String(b.email || '').trim().toLowerCase(), name = String(b.name || '').trim(), pw = String(b.password || '');
      if (!name) return L.json(res, 400, { error: 'Enter a name' });
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return L.json(res, 400, { error: 'Enter a valid email' });
      if (pw.length < 8) return L.json(res, 400, { error: 'Password must be at least 8 characters' });
      var c = await auth.createUser({ email: email, password: pw, email_confirm: true,
        app_metadata: { role: 'scanner' }, user_metadata: { name: name } });
      if (c.error) return L.json(res, 400, { error: c.error.message });
      return L.json(res, 200, { ok: true, id: c.data.user.id });
    }

    if (req.method === 'DELETE') {
      var id = String(b.id || '');
      var g = await auth.getUserById(id);
      if (g.error || !g.data.user) return L.json(res, 404, { error: 'User not found' });
      if ((g.data.user.app_metadata || {}).role !== 'scanner') return L.json(res, 403, { error: 'Only scanner logins can be removed here' });
      var d = await auth.deleteUser(id);
      if (d.error) return L.json(res, 500, { error: d.error.message });
      return L.json(res, 200, { ok: true });
    }
    return L.json(res, 405, { error: 'Method not allowed' });
  } catch (e) {
    return L.json(res, 500, { error: (e && e.message) || String(e) });
  }
};
