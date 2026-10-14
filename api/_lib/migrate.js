// تهيئة قاعدة البيانات تلقائياً بتشغيل supabase/schema.sql (آمن للتكرار)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

export function readSchema() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.join(process.cwd(), 'supabase', 'schema.sql'),
    path.join(here, '..', '..', 'supabase', 'schema.sql'),
  ];
  for (const p of candidates) {
    try { return fs.readFileSync(p, 'utf8'); } catch { /* try next */ }
  }
  throw new Error('supabase/schema.sql not found');
}

export function pgConfig(dbUrl) {
  const u = new URL(dbUrl);
  const local = ['localhost', '127.0.0.1', '::1'].includes(u.hostname);
  return {
    host: u.hostname,
    port: Number(u.port || 5432),
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
    database: decodeURIComponent(u.pathname.replace(/^\//, '')) || 'postgres',
    ssl: local ? false : { rejectUnauthorized: false },
    connectionTimeoutMillis: 15000,
    query_timeout: 90000,
  };
}

function safeHost(dbUrl) {
  try { const u = new URL(dbUrl); return `${u.hostname}:${u.port || 5432}`; } catch { return 'invalid-url'; }
}

// يجرب الروابط بالترتيب حتى ينجح أحدها
export async function runMigration(dbUrls, log = console.log) {
  const sql = readSchema();
  let lastError = null;
  for (const dbUrl of dbUrls) {
    let client;
    try {
      client = new pg.Client(pgConfig(dbUrl));
      client.on('error', (e) => { lastError = e; });
      await client.connect();
    } catch (e) {
      lastError = e;
      log(`   ↳ could not connect to ${safeHost(dbUrl)}: ${e.message}`);
      if (client) await client.end().catch(() => {});
      continue;
    }
    try {
      await client.query(sql);
      const r = await client.query('select public.crm_status() as s');
      return { host: safeHost(dbUrl), status: r.rows[0].s };
    } finally {
      await client.end().catch(() => {});
    }
  }
  throw lastError || new Error('no database url');
}
