// /api/re-files — صور ومستندات العقارات في Supabase Storage
//   upload: روابط رفع موقّعة (الملف يُرفع من المتصفح مباشرة إلى Supabase)
//   sign:   روابط مؤقتة لفتح المستندات الخاصة (وثيقة الملكية، المخطط...)
//   delete: حذف ملف — purge: حذف كل ملفات عقار قبل حذفه (للمدير)
// الصلاحية: أعضاء بوابة العقارات فقط.
import crypto from 'node:crypto';
import { env } from './_lib/env.js';
import { serverClient, getCaller, readBody, send } from './_lib/supa.js';

// re-media عام (الصور والفيديو تظهر للعميل في صفحة العقارات) — re-docs خاص
const BUCKETS = {
  're-media': { public: true, fileSizeLimit: 52428800, allowedMimeTypes: ['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp', 'video/x-m4v'] },
  're-docs': { public: false, fileSizeLimit: 26214400 },
};
const KIND_BUCKET = { photo: 're-media', video: 're-media', deed: 're-docs', plan: 're-docs', other: 're-docs' };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let bucketsReady = false;

async function ensureBuckets(admin) {
  if (bucketsReady) return;
  for (const [id, opt] of Object.entries(BUCKETS)) {
    const { data, error } = await admin.storage.getBucket(id);
    if (data && !error) continue;
    const { error: e2 } = await admin.storage.createBucket(id, opt);
    if (e2 && !/exist|duplicate/i.test(String(e2.message))) throw new Error(`تعذّر تجهيز مساحة التخزين (${id}): ${e2.message}`);
  }
  bucketsReady = true;
}

const canRealEstate = (team) => Boolean(team && (team.role === 'admin' || (team.portals || []).includes('realestate')));

function extOf(name, mime) {
  const m = String(name || '').toLowerCase().match(/\.([a-z0-9]{1,5})$/);
  if (m) return `.${m[1]}`;
  const map = { 'image/jpeg': '.jpg', 'image/png': '.png', 'image/webp': '.webp', 'image/heic': '.heic', 'video/mp4': '.mp4', 'video/quicktime': '.mov', 'application/pdf': '.pdf' };
  return map[String(mime || '').toLowerCase()] || '';
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
  const cfg = env();
  if (!cfg.url || !cfg.serviceKey) {
    return send(res, 400, { error: 'missing_service_key', message: 'رفع الملفات يحتاج مفتاح Supabase السري في Vercel (SUPABASE_SECRET_KEY).' });
  }
  try {
    const admin = serverClient(cfg, cfg.serviceKey);
    const body = await readBody(req);
    const caller = await getCaller(req, admin);
    if (!caller) return send(res, 401, { error: 'unauthorized', message: 'سجّل الدخول أولاً.' });
    if (!canRealEstate(caller.team)) return send(res, 403, { error: 'forbidden', message: 'هذه الميزة لبوابة العقارات فقط.' });

    if (body.action === 'upload') {
      if (!UUID.test(String(body.property_id || ''))) return send(res, 400, { error: 'bad_property', message: 'العقار غير صحيح.' });
      const { data: prop } = await admin.from('re_properties').select('id').eq('id', body.property_id).maybeSingle();
      if (!prop) return send(res, 404, { error: 'not_found', message: 'العقار غير موجود.' });
      await ensureBuckets(admin);
      const files = Array.isArray(body.files) ? body.files.slice(0, 20) : [];
      const out = [];
      for (const f of files) {
        const kind = Object.hasOwn(KIND_BUCKET, f.kind) ? f.kind : 'other';
        const bucket = KIND_BUCKET[kind];
        const id = crypto.randomUUID();
        const path = `${prop.id}/${id}${extOf(f.name, f.mime)}`;
        let up = await admin.storage.from(bucket).createSignedUploadUrl(path);
        if (up.error && /bucket.*not.*found|not.?found/i.test(String(up.error.message))) {
          // مساحة التخزين حُذفت يدوياً؟ أعد إنشاءها مرة واحدة
          bucketsReady = false; await ensureBuckets(admin);
          up = await admin.storage.from(bucket).createSignedUploadUrl(path);
        }
        if (up.error) throw up.error;
        const item = { kind, bucket, path, token: up.data.token };
        if (f.thumb && kind === 'photo') {
          const tpath = `${prop.id}/${id}_t.jpg`;
          const t = await admin.storage.from(bucket).createSignedUploadUrl(tpath);
          if (t.error) throw t.error;
          item.thumb_path = tpath; item.thumb_token = t.data.token;
        }
        out.push(item);
      }
      return send(res, 200, { ok: true, files: out });
    }

    if (body.action === 'sign') {
      const ids = (Array.isArray(body.ids) ? body.ids : []).filter((x) => UUID.test(String(x))).slice(0, 60);
      if (!ids.length) return send(res, 200, { ok: true, urls: {} });
      const { data: rows, error } = await admin.from('re_files').select('id,bucket,path,name').in('id', ids);
      if (error) throw error;
      const urls = {};
      for (const r of rows || []) {
        if (r.bucket === 're-media') { urls[r.id] = admin.storage.from(r.bucket).getPublicUrl(r.path).data.publicUrl; continue; }
        const s = await admin.storage.from(r.bucket).createSignedUrl(r.path, 900, body.download ? { download: r.name || true } : undefined);
        if (!s.error) urls[r.id] = s.data.signedUrl;
      }
      return send(res, 200, { ok: true, urls });
    }

    if (body.action === 'delete') {
      if (!UUID.test(String(body.id || ''))) return send(res, 400, { error: 'bad_id' });
      const { data: r } = await admin.from('re_files').select('*').eq('id', body.id).maybeSingle();
      if (!r) return send(res, 200, { ok: true });
      // الموظف يحذف الصور والفيديو فقط — حذف المستندات (وثيقة الملكية...) للمدير
      if ((!['photo', 'video'].includes(r.kind) || r.bucket !== 're-media') && caller.team.role !== 'admin') {
        return send(res, 403, { error: 'forbidden', message: 'حذف المستندات للمدير فقط.' });
      }
      const paths = [r.path, r.thumb_path].filter(Boolean);
      const rm = await admin.storage.from(r.bucket).remove(paths);
      if (rm.error && !/not.?found/i.test(String(rm.error.message))) throw rm.error;
      const { error } = await admin.from('re_files').delete().eq('id', r.id);
      if (error) throw error;
      return send(res, 200, { ok: true });
    }

    if (body.action === 'purge') {
      if (caller.team.role !== 'admin') return send(res, 403, { error: 'forbidden', message: 'حذف العقار للمدير فقط.' });
      if (!UUID.test(String(body.property_id || ''))) return send(res, 400, { error: 'bad_property' });
      const { data: rows, error } = await admin.from('re_files').select('bucket,path,thumb_path').eq('property_id', body.property_id);
      if (error) throw error;
      const byBucket = {};
      for (const r of rows || []) (byBucket[r.bucket] ||= []).push(...[r.path, r.thumb_path].filter(Boolean));
      for (const [bucket, paths] of Object.entries(byBucket)) {
        for (let i = 0; i < paths.length; i += 100) await admin.storage.from(bucket).remove(paths.slice(i, i + 100));
      }
      return send(res, 200, { ok: true, removed: Object.values(byBucket).flat().length });
    }

    return send(res, 400, { error: 'unknown_action' });
  } catch (e) {
    console.error('[re-files]', e);
    return send(res, 500, { error: 'server_error', message: String(e?.message || e) });
  }
}
