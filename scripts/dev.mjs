// تشغيل محلي اختياري: node scripts/dev.mjs  (بعد npm run build)
// يخدم dist/ ويشغّل دوال /api مثل Vercel. المتغيرات تُقرأ من .env إن وجد.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const envFile = path.join(root, '.env');
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
  }
}
const dist = path.join(root, 'dist');
const port = Number(process.env.PORT || 3000);
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.webp': 'image/webp', '.svg': 'image/svg+xml', '.pdf': 'application/pdf', '.woff2': 'font/woff2', '.txt': 'text/plain',
};

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  try {
    if (url.pathname.startsWith('/api/')) {
      const name = url.pathname.slice(5).replace(/[^a-z0-9-]/gi, '');
      const file = path.join(root, 'api', `${name}.js`);
      if (!fs.existsSync(file)) { res.statusCode = 404; return res.end('not found'); }
      let raw = '';
      for await (const chunk of req) raw += chunk;
      if (raw && (req.headers['content-type'] || '').includes('json')) { try { req.body = JSON.parse(raw); } catch { req.body = {}; } }
      req.query = Object.fromEntries(url.searchParams);
      const mod = await import(pathToFileURL(file).href);
      return await mod.default(req, res);
    }
    let p = url.pathname;
    if (/^\/p(\/[^/]*)?\/?$/.test(p)) p = '/p.html';
    if (/^\/r\/[^/]+\/?$/.test(p)) p = '/r.html';
    if (p.endsWith('/')) p += 'index.html';
    let file = path.join(dist, decodeURIComponent(p));
    if (!file.startsWith(dist)) { res.statusCode = 403; return res.end(); }
    if (!fs.existsSync(file) && fs.existsSync(file + '.html')) file += '.html';
    if (!fs.existsSync(file)) { res.statusCode = 404; return res.end('not found'); }
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    fs.createReadStream(file).pipe(res);
  } catch (e) {
    console.error(e);
    res.statusCode = 500; res.end(String(e));
  }
}).listen(port, () => console.log(`Masar running on http://localhost:${port}`));
