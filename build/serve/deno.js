import { extname, join, resolve, sep } from 'node:path';
const dir = Deno.env.get('PHANTOM_SERVE_DIR');
if (!dir) { console.error('PHANTOM_SERVE_DIR not set'); Deno.exit(1); }
const root = resolve(dir);
const assets = ['.html', '.js', '.mjs', '.map', '.wasm', '.css', '.json', '.txt', '.xml', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.otf', '.ttf', '.woff', '.woff2'];
function mime(p) {
  const e = extname(p).toLowerCase();
  if (e === '.wasm') return 'application/wasm';
  if (e === '.js' || e === '.mjs') return 'text/javascript';
  if (e === '.html') return 'text/html';
  if (e === '.css') return 'text/css';
  if (e === '.otf') return 'font/otf';
  return 'application/octet-stream';
}
const host = Deno.env.get('PHANTOM_SERVE_HOST') || '0.0.0.0';
Deno.serve({ port: 8080, hostname: host }, async function(req) {
  const url = new URL(req.url);
  let pathname;
  try { pathname = decodeURIComponent(url.pathname); } catch { pathname = url.pathname; }
  const file = join(root, pathname);
  console.log(req.method + ' ' + url.pathname);
  if (file !== root && !file.startsWith(root + sep)) {
    return new Response('not found', { status: 404 });
  }
  const names = [file, join(file, 'index.html')];
  if (!assets.includes(extname(pathname).toLowerCase())) names.push(join(root, 'shell.html'));
  for (const f of names) {
    try {
      const data = await Deno.readFile(f);
      return new Response(data, { headers: { 'Content-Type': mime(f) } });
    } catch {
      // Try the next candidate.
    }
  }
  return new Response('not found', { status: 404 });
});
console.log('phantom serve: http://localhost:8080 serving ' + dir);
