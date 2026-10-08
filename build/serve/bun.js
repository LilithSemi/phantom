const dir = process.env.PHANTOM_SERVE_DIR;
if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
const path = require('path');
const root = path.resolve(dir);
function mime(p) {
  if (p.endsWith('.wasm')) return 'application/wasm';
  if (p.endsWith('.js')) return 'text/javascript';
  if (p.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}
const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
const server = Bun.serve({
  port: 8080,
  hostname: host,
  async fetch(req) {
    const url = new URL(req.url);
    let pathname = url.pathname === '/' ? '/index.html' : url.pathname;
    if (!/\.[^/]*$/.test(pathname)) pathname += '/index.html';
    const file = path.join(root, pathname);
    console.log(req.method + ' ' + url.pathname);
    if (file !== root && !file.startsWith(root + path.sep)) {
      return new Response('not found', { status: 404 });
    }
    const f = Bun.file(file);
    if (!(await f.exists())) return new Response('not found', { status: 404 });
    return new Response(f, { headers: { 'Content-Type': mime(file) } });
  },
});
console.log('phantom serve: http://localhost:' + server.port + ' serving ' + dir);
