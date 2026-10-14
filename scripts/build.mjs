// بناء الموقع على Vercel:
// 1) نسخ public → dist
// 2) كتابة dist/config.js من متغيرات البيئة (رابط Supabase والمفتاح العام)
// 3) تهيئة/تحديث قاعدة البيانات تلقائياً (إن توفر رابط Postgres) — لا يوقف البناء عند الفشل
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { env } from '../api/_lib/env.js';
import { runMigration } from '../api/_lib/migrate.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(root, 'public');
const out = path.join(root, 'dist');
const cfg = env();

fs.rmSync(out, { recursive: true, force: true });
fs.cpSync(src, out, { recursive: true });

const config = {
  supabaseUrl: cfg.url,
  supabaseKey: cfg.anonKey,
  siteUrl: cfg.siteUrl,
  builtAt: new Date().toISOString(),
  commit: (process.env.VERCEL_GIT_COMMIT_SHA || '').slice(0, 7) || null,
};
fs.writeFileSync(path.join(out, 'config.js'), `window.MASAR_CONFIG = ${JSON.stringify(config, null, 2)};\n`);

for (const file of ['index.html', 'p.html', 'r.html']) {
  const p = path.join(out, file);
  if (!fs.existsSync(p)) continue;
  const html = fs.readFileSync(p, 'utf8').replaceAll('%%SITE_URL%%', cfg.siteUrl || '');
  fs.writeFileSync(p, html);
}

console.log('▸ Masar build');
console.log(`  Supabase URL: ${cfg.url ? 'yes' : 'MISSING'} · public key: ${cfg.anonKey ? 'yes' : 'MISSING'} · secret key: ${cfg.serviceKey ? 'yes' : 'missing'}`);
console.log(`  Site URL: ${cfg.siteUrl || '(relative)'} · email sending: ${cfg.smtp.configured ? 'on' : 'off (uses mail app)'}`);

if (process.env.SKIP_MIGRATION === '1') {
  console.log('  Database: migration skipped (SKIP_MIGRATION=1)');
} else if (!cfg.dbUrls.length) {
  console.log('  Database: no POSTGRES_URL — open the app and press "تهيئة قاعدة البيانات", or run supabase/schema.sql manually.');
} else {
  try {
    const r = await runMigration(cfg.dbUrls, (m) => console.log(m));
    console.log(`  Database: ready ✓ (${r.host}) ${JSON.stringify(r.status)}`);
  } catch (e) {
    console.warn(`  Database: automatic setup failed — ${e.message}`);
    console.warn('  The app will offer to initialise it, or run supabase/schema.sql in the Supabase SQL editor.');
  }
}
console.log('✓ Build finished → dist/');
