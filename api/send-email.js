// /api/send-email — إرسال الخطاب بالبريد مباشرة من النظام مع إرفاق الملف التعريفي PDF
// يعمل فقط إذا أضفتم إعدادات البريد (GMAIL_USER + GMAIL_APP_PASSWORD أو SMTP_*) في Vercel.
// بدونها يستخدم النظام تطبيق البريد في جهازكم تلقائياً.
import fs from 'node:fs';
import path from 'node:path';
import nodemailer from 'nodemailer';
import { env } from './_lib/env.js';
import { serverClient, getCaller, readBody, send } from './_lib/supa.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PROFILE_FILE = 'Al-Tayeb-Law-Firm-Profile.pdf';

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function isRtl(s) {
  const ar = (s.match(/[؀-ۿ]/g) || []).length;
  const la = (s.match(/[A-Za-z]/g) || []).length;
  return ar >= la;
}

function inline(line) {
  let h = esc(line);
  h = h.replace(/\*([^*\n]+)\*/g, '<strong>$1</strong>');
  h = h.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:#8a6424;text-decoration:underline">$1</a>');
  return h;
}

export function buildHtml({ text, base, firm }) {
  const blocks = String(text || '').replace(/\r/g, '').split(/\n{2,}/);
  const body = blocks.map((block) => {
    const lines = block.split('\n');
    // سطر يحتوي رابطاً فقط → زر
    if (lines.length === 1 && /^https?:\/\/\S+$/.test(lines[0].trim())) {
      const url = lines[0].trim();
      return `<p style="margin:22px 0;text-align:center"><a href="${esc(url)}" style="display:inline-block;background:#1c1a17;color:#e9cf8f;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:600;font-size:15px">عرض الملف التعريفي &nbsp;|&nbsp; View Company Profile</a></p>`;
    }
    const rtl = isRtl(block);
    const html = lines.map((l) => {
      if (/^https?:\/\/\S+$/.test(l.trim())) {
        const url = l.trim();
        return `<a href="${esc(url)}" style="display:inline-block;margin-top:6px;background:#1c1a17;color:#e9cf8f;text-decoration:none;padding:10px 20px;border-radius:999px;font-weight:600;font-size:14px">عرض الملف التعريفي | View Profile</a>`;
      }
      return inline(l);
    }).join('<br>');
    return `<p dir="${rtl ? 'rtl' : 'ltr'}" style="margin:0 0 16px;text-align:${rtl ? 'right' : 'left'};line-height:1.9;font-size:15px;color:#2a2722">${html}</p>`;
  }).join('\n');

  const emblem = base ? `<img src="${esc(base)}/assets/brand/emblem.png" width="86" alt="Al-Tayeb" style="display:block;margin:0 auto 6px;border:0">` : '';
  const insta = firm.instagram ? `https://instagram.com/${String(firm.instagram).replace(/^@/, '').replace(/^https?:\/\/(www\.)?instagram\.com\//, '').replace(/\/$/, '')}` : '';
  return `<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#efeeeb">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#efeeeb;padding:24px 10px"><tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;font-family:Tahoma,Arial,sans-serif">
<tr><td style="background:#1c1a17;padding:26px 20px 20px;text-align:center">
${emblem}
<div style="font-family:Georgia,'Times New Roman',serif;font-size:30px;color:#d9b46a;letter-spacing:.5px">Al-Tayeb</div>
<div style="font-size:12px;color:#cdbb95;margin-top:4px">Law Firm &amp; Legal Consultants &nbsp;·&nbsp; ${esc(firm.name_ar || 'مكتب الطيب للمحاماة والاستشارات القانونية')}</div>
</td></tr>
<tr><td style="height:3px;background:linear-gradient(90deg,#9a7330,#e9cf8f,#9a7330);background-color:#c9a15b"></td></tr>
<tr><td style="padding:30px 30px 14px">${body}</td></tr>
<tr><td style="padding:18px 30px 26px;border-top:1px solid #ece7dc;text-align:center;font-size:12px;color:#7a7466;line-height:1.8">
${esc(firm.address_ar || '')}<br>
${firm.phone ? `☎ ${esc(firm.phone)}` : ''}${firm.whatsapp ? ` &nbsp;|&nbsp; ${esc(firm.whatsapp)}` : ''}${firm.email ? ` &nbsp;|&nbsp; <a href="mailto:${esc(firm.email)}" style="color:#8a6424">${esc(firm.email)}</a>` : ''}
${insta ? `<br><a href="${esc(insta)}" style="color:#8a6424">Instagram</a>` : ''}
</td></tr>
</table></td></tr></table></body></html>`;
}

async function loadProfilePdf(req, base) {
  const candidates = [
    path.join(process.cwd(), 'public', 'assets', 'altayeb-profile.pdf'),
    path.join(process.cwd(), 'dist', 'assets', 'altayeb-profile.pdf'),
  ];
  for (const p of candidates) {
    try { return fs.readFileSync(p); } catch { /* next */ }
  }
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  const origin = base || (host ? `https://${host}` : '');
  if (!origin) return null;
  try {
    const r = await fetch(`${origin}/assets/altayeb-profile.pdf`);
    if (r.ok) return Buffer.from(await r.arrayBuffer());
  } catch { /* ignore */ }
  return null;
}

export default async function handler(req, res) {
  const cfg = env();
  try {
    if (req.method === 'GET') {
      return send(res, 200, { configured: cfg.smtp.configured, from: cfg.smtp.configured ? (cfg.smtp.from || cfg.smtp.user) : null });
    }
    if (req.method !== 'POST') return send(res, 405, { error: 'method_not_allowed' });
    if (!cfg.smtp.configured) {
      return send(res, 400, { error: 'smtp_not_configured', message: 'إعدادات البريد غير موجودة في Vercel (GMAIL_USER و GMAIL_APP_PASSWORD).' });
    }
    if (!cfg.url || !cfg.serviceKey) return send(res, 400, { error: 'missing_service_key', message: 'مفتاح Supabase السري غير موجود.' });

    const admin = serverClient(cfg, cfg.serviceKey);
    const caller = await getCaller(req, admin);
    if (!caller) return send(res, 401, { error: 'unauthorized', message: 'سجّل الدخول أولاً.' });
    // بريد المكتب (الخطابات) لبوابة الشركات فقط
    if (!(caller.team.role === 'admin' || (caller.team.portals || []).includes('companies'))) {
      return send(res, 403, { error: 'forbidden', message: 'إرسال خطابات المكتب لبوابة الشركات فقط.' });
    }

    const b = await readBody(req);
    const to = String(b.to || '').split(/[,;\s]+/).map((s) => s.trim()).filter(Boolean);
    if (!to.length || to.some((x) => !EMAIL_RE.test(x))) return send(res, 400, { error: 'bad_email', message: 'البريد الإلكتروني للمستلم غير صحيح.' });
    const subject = String(b.subject || '').trim().slice(0, 250);
    const text = String(b.text || '').slice(0, 20000);
    if (!subject || !text.trim()) return send(res, 400, { error: 'empty', message: 'الموضوع ونص الخطاب مطلوبان.' });

    const { data: firm } = await admin.from('crm_settings').select('*').eq('id', 1).maybeSingle();
    const host = req.headers['x-forwarded-host'] || req.headers.host;
    const base = (firm?.site_url || cfg.siteUrl || (host ? `https://${host}` : '')).replace(/\/+$/, '');

    const attachments = [];
    if (b.attachProfile !== false) {
      const pdf = await loadProfilePdf(req, base);
      if (pdf) attachments.push({ filename: PROFILE_FILE, content: pdf, contentType: 'application/pdf' });
    }

    const transporter = nodemailer.createTransport({
      host: cfg.smtp.host,
      port: cfg.smtp.port,
      secure: cfg.smtp.port === 465,
      auth: { user: cfg.smtp.user, pass: cfg.smtp.pass },
    });
    const fromName = 'Al-Tayeb Law Firm | مكتب الطيب للمحاماة';
    const info = await transporter.sendMail({
      from: cfg.smtp.from || { name: fromName, address: cfg.smtp.user },
      to,
      cc: b.ccMe ? caller.team.email : undefined,
      replyTo: caller.team.email || undefined,
      subject,
      text: text.replace(/\*([^*\n]+)\*/g, '$1'),
      html: buildHtml({ text, base, firm: firm || {} }),
      attachments,
    });
    return send(res, 200, { ok: true, messageId: info.messageId, attached: attachments.length > 0 });
  } catch (e) {
    console.error('[send-email]', e);
    return send(res, 500, { error: 'send_failed', message: String(e?.message || e) });
  }
}
