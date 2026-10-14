import { createClient } from '@supabase/supabase-js';

export function serverClient(cfg, key) {
  return createClient(cfg.url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

// المستخدم صاحب الطلب (من رمز الدخول) + صفه في جدول الفريق
export async function getCaller(req, admin) {
  const h = req.headers['authorization'] || req.headers['Authorization'] || '';
  const token = h.startsWith('Bearer ') ? h.slice(7).trim() : '';
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  const { data: team } = await admin
    .from('crm_team').select('*')
    .eq('user_id', data.user.id).eq('active', true)
    .maybeSingle();
  return team ? { user: data.user, team } : null;
}

export async function readBody(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  if (typeof req.body === 'string') { try { return JSON.parse(req.body); } catch { return {}; } }
  return {};
}

export function send(res, status, payload) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(payload));
}
