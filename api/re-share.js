// /api/re-share — صفحة العقارات المرسلة للعميل (/r/رمز)
//   GET  ?t=رمز            بيانات العرض (بدون بيانات المالك أو العنوان الدقيق أو الملاحظات الداخلية)
//   POST {t, property_id, action: like | dislike | viewing, reason}  ردّ العميل → يظهر في سجل العميل
import { env } from './_lib/env.js';
import { serverClient, readBody, send } from './_lib/supa.js';

const TOKEN = /^[a-z0-9]{10,40}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE = 'id,ref,title,category,subtype,category_other,purpose,status,price,price_period,negotiable,governorate,area,land_area,built_area,bedrooms,bathrooms,parking,floors,age_years,furnished,features,video_url,description';
const MINUTES = (n) => n * 60 * 1000;

const firstName = (name) => String(name || '').trim().replace(/^(السيد[ة]?|الأستاذ[ة]?|د\.|Mr\.?|Mrs\.?|Ms\.?)\s+/i, '').split(/\s+/)[0] || '';

async function loadShare(admin, token) {
  if (!TOKEN.test(String(token || ''))) return null;
  const { data } = await admin.from('re_shares').select('*').eq('token', token).maybeSingle();
  return data && !data.revoked ? data : null;
}

export default async function handler(req, res) {
  const cfg = env();
  if (!cfg.url || !cfg.serviceKey) return send(res, 503, { error: 'not_configured', message: 'النظام غير مربوط بعد.' });
  const admin = serverClient(cfg, cfg.serviceKey);
  const query = new URL(req.url || '/', 'http://local').searchParams;
  try {
    if (req.method === 'GET') {
      const share = await loadShare(admin, query.get('t'));
      if (!share) return send(res, 404, { error: 'not_found', message: 'الرابط غير صحيح أو انتهت صلاحيته.' });
      const ids = (share.property_ids || []).filter((x) => UUID.test(String(x))).slice(0, 30);
      const [props, files, settings, firm, agent, client, cps] = await Promise.all([
        ids.length ? admin.from('re_properties').select(SAFE).in('id', ids) : { data: [] },
        ids.length ? admin.from('re_files').select('id,property_id,kind,bucket,path,thumb_path,sort').in('property_id', ids).in('kind', ['photo', 'video']).order('sort').order('created_at') : { data: [] },
        admin.from('re_settings').select('*').eq('id', 1).maybeSingle(),
        admin.from('crm_settings').select('phone,whatsapp,instagram,country_code').eq('id', 1).maybeSingle(),
        share.created_by ? admin.from('crm_team').select('full_name,name_en,title_ar,phone,avatar_url').eq('id', share.created_by).eq('active', true).maybeSingle() : { data: null },
        share.client_id ? admin.from('re_clients').select('id,name').eq('id', share.client_id).maybeSingle() : { data: null },
        share.client_id && ids.length ? admin.from('re_client_props').select('property_id,status').eq('client_id', share.client_id).in('property_id', ids) : { data: [] },
      ]);
      const st = settings.data || {};
      const fm = firm.data || {};
      const reaction = Object.fromEntries((cps.data || []).map((x) => [x.property_id, x.status]));
      const media = {};
      for (const f of files.data || []) {
        // للعميل: الصور والفيديو فقط — المستندات (وثيقة الملكية، المخطط...) لا تظهر في هذه الصفحة أبداً
        if (!['photo', 'video'].includes(f.kind) || f.bucket !== 're-media') continue;
        const list = (media[f.property_id] ||= []);
        const url = admin.storage.from(f.bucket).getPublicUrl(f.path).data.publicUrl;
        const thumb = f.thumb_path ? admin.storage.from(f.bucket).getPublicUrl(f.thumb_path).data.publicUrl : url;
        list.push({ kind: f.kind, url, thumb });
      }
      const byId = Object.fromEntries((props.data || []).map((p) => [p.id, p]));
      const properties = ids.map((id) => byId[id]).filter(Boolean).map((p) => ({ ...p, media: media[p.id] || [], reaction: reaction[p.id] || null }));

      // تسجيل فتح الصفحة (مرة كل 30 دقيقة) — المعاينة من داخل النظام لا تُحتسب
      if (query.get('preview') !== '1') {
        const last = share.last_view_at ? new Date(share.last_view_at).getTime() : 0;
        if (Date.now() - last > MINUTES(30)) {
          await admin.from('re_shares').update({ views: (share.views || 0) + 1, last_view_at: new Date().toISOString() }).eq('id', share.id);
          if (share.client_id) {
            await admin.from('re_activities').insert({ client_id: share.client_id, type: 'opened', body: `فتح صفحة العقارات المرسلة (${properties.length})`, meta: { token: share.token }, created_by: null });
          }
        }
      }
      const ag = agent.data;
      return send(res, 200, {
        brand: { name: st.brand_name || 'مكتب الطيب — الوساطة العقارية', name_en: st.brand_name_en || '', phone: st.phone || fm.phone || '', whatsapp: st.whatsapp || fm.whatsapp || '', instagram: st.instagram || fm.instagram || '', license_no: st.license_no || '', country_code: fm.country_code || '973' },
        agent: ag ? { name: ag.full_name, name_en: ag.name_en, title: ag.title_ar, phone: ag.phone, avatar: ag.avatar_url } : null,
        client: client.data ? { first_name: firstName(client.data.name) } : null,
        created_at: share.created_at,
        properties,
      });
    }

    if (req.method === 'POST') {
      const body = await readBody(req);
      const share = await loadShare(admin, body.t);
      if (!share) return send(res, 404, { error: 'not_found' });
      const action = String(body.action || '');
      if (!['like', 'dislike', 'viewing'].includes(action)) return send(res, 400, { error: 'bad_action' });
      const pid = String(body.property_id || '');
      if (!UUID.test(pid) || !(share.property_ids || []).includes(pid)) return send(res, 400, { error: 'bad_property' });
      if (!share.client_id) return send(res, 200, { ok: true });

      const { data: cp } = await admin.from('re_client_props').select('*').eq('client_id', share.client_id).eq('property_id', pid).maybeSingle();
      const reason = String(body.reason || '').trim().slice(0, 200) || null;
      let status = cp?.status || 'sent';
      if (action === 'dislike') status = 'rejected';
      else if (!['viewing', 'viewed', 'offer'].includes(status)) status = 'liked';
      const row = { client_id: share.client_id, property_id: pid, status, reason: action === 'dislike' ? reason : cp?.reason || null };
      if (cp) await admin.from('re_client_props').update({ status, reason: row.reason }).eq('id', cp.id);
      else {
        const { error: ue } = await admin.from('re_client_props').upsert({ ...row, sent_at: share.created_at, created_by: share.created_by }, { onConflict: 'client_id,property_id' });
        if (ue) throw ue;
      }

      const type = action === 'like' ? 'liked' : action === 'dislike' ? 'rejected' : 'viewing';
      const since = new Date(Date.now() - MINUTES(10)).toISOString();
      const { data: recent } = await admin.from('re_activities').select('id').eq('client_id', share.client_id).eq('property_id', pid).eq('type', type).gte('happened_at', since).limit(1);
      if (recent && recent.length && action === 'dislike' && reason) {
        // السبب يصل بعد الضغطة الأولى — نضيفه لنفس السجل
        await admin.from('re_activities').update({ body: `لا يناسبه — ${reason} (من صفحة العقارات)` }).eq('id', recent[0].id);
      } else if (!recent || !recent.length) {
        const text = action === 'like' ? 'أعجبه العقار (من صفحة العقارات)'
          : action === 'dislike' ? `لا يناسبه${reason ? ` — ${reason}` : ''} (من صفحة العقارات)`
          : 'طلب موعد معاينة (من صفحة العقارات) 🔥';
        await admin.from('re_activities').insert({ client_id: share.client_id, property_id: pid, type, body: text, meta: { via: 'page', requested: action === 'viewing' }, created_by: null });
      }
      // إعجاب أو طلب معاينة = متابعة اليوم
      if (action !== 'dislike') {
        const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Bahrain' }).format(new Date());
        const { data: cl } = await admin.from('re_clients').select('next_followup,status').eq('id', share.client_id).maybeSingle();
        if (cl && cl.status === 'active' && (!cl.next_followup || cl.next_followup > today)) {
          await admin.from('re_clients').update({ next_followup: today }).eq('id', share.client_id);
        }
      }
      return send(res, 200, { ok: true, reaction: status });
    }
    return send(res, 405, { error: 'method_not_allowed' });
  } catch (e) {
    console.error('[re-share]', e);
    return send(res, 500, { error: 'server_error', message: 'حدث خطأ — حاول مرة أخرى.' });
  }
}
