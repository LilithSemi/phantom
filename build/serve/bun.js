const dir = process.env.PHANTOM_SERVE_DIR;
if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
const path = require('path');
const root = path.resolve(dir);
function mime(p) {
  if (p.endsWith('.wasm')) return 'application/wasm';
  if (p.endsWith('.js')) return 'text/javascript';
  if (p.endsWith('.html')) return 'text/html';
  if (p.endsWith('.css')) return 'text/css';
  if (p.endsWith('.otf')) return 'font/otf';
  return 'application/octet-stream';
}
const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
const server = Bun.serve({
  port: 8080,
  hostname: host,
  async fetch(req) {
    const url = new URL(req.url);
    let pathname = url.pathname;
    const route = !/\.[^/]*$/.test(pathname);
    if (route) pathname += '/index.html';
    const file = path.join(root, pathname);
    console.log(req.method + ' ' + url.pathname);
    if (file !== root && !file.startsWith(root + path.sep)) {
      return new Response('not found', { status: 404 });
    }
    for (const name of route ? [file, path.join(root, 'index.html')] : [file]) {
      const f = Bun.file(name);
      if (await f.exists()) return new Response(f, { headers: { 'Content-Type': mime(name) } });
    }
    return new Response('not found', { status: 404 });
  },
});
console.log('phantom serve: http://localhost:' + server.port + ' serving ' + dir);
