const http = require('http');
const fs = require('fs');
const path = require('path');
const dir = process.env.PHANTOM_SERVE_DIR;
if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
const root = path.resolve(dir);
const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
const assets = ['.html', '.js', '.mjs', '.map', '.wasm', '.css', '.json', '.txt', '.xml', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.otf', '.ttf', '.woff', '.woff2'];
function mime(p) {
  const e = path.extname(p).toLowerCase();
  if (e === '.wasm') return 'application/wasm';
  if (e === '.js' || e === '.mjs') return 'text/javascript';
  if (e === '.html') return 'text/html';
  if (e === '.css') return 'text/css';
  if (e === '.otf') return 'font/otf';
  return 'application/octet-stream';
}
http.createServer(function(req, res) {
  let pathname;
  try { pathname = decodeURIComponent(req.url.split('?')[0]); } catch { pathname = req.url.split('?')[0]; }
  const file = path.join(root, pathname);
  process.stdout.write(req.method + ' ' + req.url + '\n');
  if (file !== root && !file.startsWith(root + path.sep)) {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  const names = [file, path.join(file, 'index.html')];
  if (!assets.includes(path.extname(pathname).toLowerCase())) names.push(path.join(root, 'shell.html'));
  function send(i) {
    if (i === names.length) { res.writeHead(404); res.end('not found'); return; }
    fs.readFile(names[i], function(err, data) {
      if (err) return send(i + 1);
      res.writeHead(200, { 'Content-Type': mime(names[i]) });
      res.end(data);
    });
  }
  send(0);
}).listen(8080, host, function() {
  process.stdout.write('phantom serve: http://localhost:8080 serving ' + dir + '\n');
});
