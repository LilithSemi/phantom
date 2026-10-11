const dir = process.env.PHANTOM_SERVE_DIR;
if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
const fs = require('fs');
const path = require('path');
const root = path.resolve(dir);
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
const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
const server = Bun.serve({
  port: 8080,
  hostname: host,
  async fetch(req) {
    const url = new URL(req.url);
    let pathname;
    try { pathname = decodeURIComponent(url.pathname); } catch { pathname = url.pathname; }
    const file = path.join(root, pathname);
    console.log(req.method + ' ' + url.pathname);
    if (file !== root && !file.startsWith(root + path.sep)) {
      return new Response('not found', { status: 404 });
    }
    const names = [file, path.join(file, 'index.html')];
    if (!assets.includes(path.extname(pathname).toLowerCase())) names.push(path.join(root, 'shell.html'));
    for (const name of names) {
      const stat = fs.statSync(name, { throwIfNoEntry: false });
      if (stat && stat.isFile()) return new Response(Bun.file(name), { headers: { 'Content-Type': mime(name) } });
    }
    return new Response('not found', { status: 404 });
  },
});
console.log('phantom serve: http://localhost:' + server.port + ' serving ' + dir);
