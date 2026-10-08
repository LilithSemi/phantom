import { join, resolve, sep } from 'node:path';
const dir = Deno.env.get('PHANTOM_SERVE_DIR');
if (!dir) { console.error('PHANTOM_SERVE_DIR not set'); Deno.exit(1); }
const root = resolve(dir);
function mime(p) {
  if (p.endsWith('.wasm')) return 'application/wasm';
  if (p.endsWith('.js')) return 'text/javascript';
  if (p.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}
const host = Deno.env.get('PHANTOM_SERVE_HOST') || '0.0.0.0';
Deno.serve({ port: 8080, hostname: host }, async function(req) {
  const url = new URL(req.url);
  let pathname = url.pathname === '/' ? '/index.html' : url.pathname;
  if (!/\.[^/]*$/.test(pathname)) pathname += '/index.html';
  const file = join(root, pathname);
  console.log(req.method + ' ' + url.pathname);
  if (file !== root && !file.startsWith(root + sep)) {
    return new Response('not found', { status: 404 });
  }
  try {
    const data = await Deno.readFile(file);
    return new Response(data, { headers: { 'Content-Type': mime(file) } });
  } catch {
    return new Response('not found', { status: 404 });
  }
});
console.log('phantom serve: http://localhost:8080 serving ' + dir);
