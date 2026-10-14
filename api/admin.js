// /api/admin — الإعداد الأول، تهيئة قاعدة البيانات، وإدارة حسابات الفريق
import { env } from './_lib/env.js';
import { serverClient, getCaller, readBody, send } from './_lib/supa.js';
import { runMigration } from './_lib/migrate.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function status(cfg) {
  const out = {
    supabase: Boolean(cfg.url && cfg.anonKey),
    serviceKey: Boolean(cfg.serviceKey),
    dbUrl: cfg.dbUrls.length > 0,
    smtp: cfg.smtp.configured,
    schema: null,
    hasAdmin: null,
  };
  const key = cfg.serviceKey || cfg.anonKey;
  if (cfg.url && key) {
    try {
      const c = serverClient(cfg, key);
      const { data, error } = await c.rpc('crm_status');
      if (error) { out.schema = false; out.schemaError = error.message; }
      else { out.schema = true; out.hasAdmin = Boolean(data?.has_admin); out.version = data?.version ?? null; }
    } catch (e) {
      out.schema = false; out.schemaError = String(e.message || e);
    }
  }
  return out;
}

function cleanEmail(v) { return String(v || '').trim().toLowerCase(); }
function text(v, max = 200) { const s = String(v ?? '').trim(); return s ? s.slice(0, max) : null; }

// ينشئ حساب دخول أو يعيد الحساب الموجود بنفس البريد (بدون تغيير كلمة مروره)
async function ensureAuthUser(admin, email, password) {
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (!error && data?.user) return { id: data.user.id, existing: false };
  const msg = String(error?.message || '');
  if (!(error?.code === 'email_exists' || error?.status === 422 || /already|registered|exists/i.test(msg))) {
    throw new Error(msg || 'تعذر إنشاء الحساب');
  }
  for (let page = 1; page <= 50; page++) {
    const { data: list, error: e2 } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (e2) throw e2;
    const u = (list?.users || []).find((x) => (x.email || '').toLowerCase() === email);
    if (u) return { id: u.id, existing: true };
    if (!list?.users || list.users.length < 200) break;
  }
  throw new Error(msg || 'البريد مسجل مسبقاً');
}

function teamFields(b) {
  return {
    full_name: text(b.full_name, 120),
    name_en: text(b.name_en, 120),
    title_ar: text(b.title_ar, 160),
    title_en: text(b.title_en, 160),
    phone: text(b.phone, 40),
    avatar_url: text(b.avatar_url, 300),
  };
}

// البوابات: companies (الشركات) و realestate (العقارات) — المدير له البوابتان دائماً
const PORTALS = ['companies', 'realestate'];
function portalsOf(b, role) {
  if (role === 'admin') return [...PORTALS];
  const list = Array.isArray(b.portals) ? b.portals.filter((p) => PORTALS.includes(p)) : [];
  return list.length ? [...new Set(list)] : ['companies'];
}
function pctOf(v) {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 && n <= 100 ? Math.round(n * 100) / 100 : null;
}

export default async function handler(req, res) {
  const cfg = env();
  const query = new URL(req.url || '/', 'http://local').searchParams;
  try {
    const body = req.method === 'POST' ? await readBody(req) : {};
    const action = (req.method === 'GET' ? query.get('action') : body.action) || 'status';

    if (action === 'status') return send(res, 200, await status(cfg));
    if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });

    if (!cfg.url) return send(res, 400, { error: 'missing_supabase', message: 'لم يتم ربط Supabase بعد (SUPABASE_URL غير موجود).' });
    if (!cfg.serviceKey) {
      return send(res, 400, { error: 'missing_service_key', message: 'مفتاح Supabase السري غير موجود (SUPABASE_SECRET_KEY أو SUPABASE_SERVICE_ROLE_KEY).' });
    }
    const admin = serverClient(cfg, cfg.serviceKey);

    // ---------------- تهيئة قاعدة البيانات ----------------
    if (action === 'migrate') {
      const st = await status(cfg);
      if (st.schema && st.hasAdmin) {
        const caller = await getCaller(req, admin);
        if (!caller || caller.team.role !== 'admin') return send(res, 403, { error: 'forbidden', message: 'هذا الإجراء للمدير فقط.' });
      }
      if (!cfg.dbUrls.length) {
        return send(res, 400, { error: 'missing_db_url', message: 'رابط قاعدة البيانات غير موجود (POSTGRES_URL). شغّل ملف schema.sql يدوياً من Supabase.' });
      }
      const result = await runMigration(cfg.dbUrls, () => {});
      return send(res, 200, { ok: true, ...result });
    }

    // ---------------- إنشاء حساب المدير لأول مرة ----------------
    if (action === 'setup') {
      const st = await status(cfg);
      if (!st.schema) return send(res, 409, { error: 'schema_missing', message: 'قاعدة البيانات غير مهيأة بعد.' });
      if (st.hasAdmin) return send(res, 409, { error: 'already_setup', message: 'تم إعداد النظام مسبقاً. سجّل الدخول.' });
      const email = cleanEmail(body.email);
      const password = String(body.password || '');
      const f = teamFields(body);
      if (!EMAIL_RE.test(email)) return send(res, 400, { error: 'bad_email', message: 'البريد الإلكتروني غير صحيح.' });
      if (password.length < 8) return send(res, 400, { error: 'weak_password', message: 'الرقم السري يجب أن يكون 8 خانات على الأقل (أرقام أو حروف).' });
      if (!f.full_name) return send(res, 400, { error: 'missing_name', message: 'الاسم مطلوب.' });

      // أول حساب مدير: بريد المكتب فقط (أو ADMIN_EMAIL إن أُضيف في Vercel)
      const { data: st1 } = await admin.from('crm_settings').select('email').eq('id', 1).maybeSingle();
      const allowed = cleanEmail(process.env.ADMIN_EMAIL || st1?.email || '');
      if (allowed && email !== allowed) {
        return send(res, 403, { error: 'admin_email_only', message: `لأمان النظام، حساب المدير الأول يكون ببريد المكتب: ${allowed}` });
      }
      const u = await ensureAuthUser(admin, email, password);
      const row = { ...f, email, user_id: u.id, role: 'admin', active: true, portals: [...PORTALS] };
      const { data: existing } = await admin.from('crm_team').select('id').eq('email', email).maybeSingle();
      const q = existing
        ? admin.from('crm_team').update(row).eq('id', existing.id).select().single()
        : admin.from('crm_team').insert(row).select().single();
      const { data: team, error } = await q;
      if (error) throw error;
      return send(res, 200, { ok: true, existing: u.existing, team });
    }

    // ---------------- باقي الإجراءات للمدير فقط ----------------
    const caller = await getCaller(req, admin);
    if (!caller) return send(res, 401, { error: 'unauthorized', message: 'سجّل الدخول أولاً.' });
    if (caller.team.role !== 'admin') return send(res, 403, { error: 'forbidden', message: 'هذا الإجراء للمدير فقط.' });

    if (action === 'create_user') {
      const email = cleanEmail(body.email);
      const password = String(body.password || '');
      const role = ['admin', 'partner', 'member'].includes(body.role) ? body.role : 'member';
      const f = teamFields(body);
      if (!EMAIL_RE.test(email)) return send(res, 400, { error: 'bad_email', message: 'البريد الإلكتروني غير صحيح.' });
      if (password.length < 8) return send(res, 400, { error: 'weak_password', message: 'الرقم السري يجب أن يكون 8 خانات على الأقل (أرقام أو حروف).' });
      if (!f.full_name) return send(res, 400, { error: 'missing_name', message: 'الاسم مطلوب.' });

      const u = await ensureAuthUser(admin, email, password);
      const { data: byUser } = await admin.from('crm_team').select('id').eq('user_id', u.id).maybeSingle();
      const { data: byEmail } = await admin.from('crm_team').select('id').eq('email', email).maybeSingle();
      const existingId = byUser?.id || byEmail?.id;
      const portals = portalsOf(body, role);
      const row = { ...f, email, user_id: u.id, role, active: true, portals, re_agent_pct: pctOf(body.re_agent_pct) };
      const q = existingId
        ? admin.from('crm_team').update(row).eq('id', existingId).select().single()
        : admin.from('crm_team').insert(row).select().single();
      const { data: team, error } = await q;
      if (error) throw error;
      // صاحب العمولة في الشركات (نور) — فقط إذا كان له بوابة الشركات
      if (body.commission && portals.includes('companies')) {
        await admin.from('crm_settings').update({ partner_id: team.id }).eq('id', 1);
      }
      return send(res, 200, { ok: true, existing: u.existing, team });
    }

    if (action === 'set_password') {
      const password = String(body.password || '');
      if (password.length < 8) return send(res, 400, { error: 'weak_password', message: 'الرقم السري يجب أن يكون 8 خانات على الأقل (أرقام أو حروف).' });
      const { data: member } = await admin.from('crm_team').select('user_id').eq('id', body.team_id).maybeSingle();
      if (!member?.user_id) return send(res, 404, { error: 'not_found', message: 'العضو غير موجود.' });
      const { error } = await admin.auth.admin.updateUserById(member.user_id, { password });
      if (error) throw error;
      return send(res, 200, { ok: true });
    }

    return send(res, 400, { error: 'unknown_action' });
  } catch (e) {
    console.error('[admin]', e);
    return send(res, 500, { error: 'server_error', message: String(e?.message || e) });
  }
}
