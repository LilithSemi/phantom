const http = require('http');
const fs = require('fs');
const path = require('path');
const dir = process.env.PHANTOM_SERVE_DIR;
if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
const root = path.resolve(dir);
const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
function mime(p) {
  if (p.endsWith('.wasm')) return 'application/wasm';
  if (p.endsWith('.js')) return 'text/javascript';
  if (p.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}
http.createServer(function(req, res) {
  let pathname;
  try { pathname = decodeURIComponent(req.url.split('?')[0]); } catch { pathname = req.url.split('?')[0]; }
  if (pathname === '/') pathname = '/index.html';
  else if (!path.extname(pathname)) pathname += '/index.html';
  const file = path.join(root, pathname);
  process.stdout.write(req.method + ' ' + req.url + '\n');
  if (file !== root && !file.startsWith(root + path.sep)) {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  fs.readFile(file, function(err, data) {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': mime(file) });
    res.end(data);
  });
}).listen(8080, host, function() {
  process.stdout.write('phantom serve: http://localhost:8080 serving ' + dir + '\n');
});
