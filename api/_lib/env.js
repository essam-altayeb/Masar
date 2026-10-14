// قراءة متغيرات البيئة بكل الأسماء المحتملة (تكامل Vercel ↔ Supabase أو الإدخال اليدوي)
export function env() {
  const e = process.env;
  const pick = (...names) => {
    for (const n of names) {
      const v = (e[n] || '').trim();
      if (v) return v;
    }
    return '';
  };

  const url = pick('SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_URL', 'VITE_SUPABASE_URL').replace(/\/+$/, '');
  const anonKey = pick(
    'SUPABASE_PUBLISHABLE_KEY', 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY',
    'SUPABASE_ANON_KEY', 'NEXT_PUBLIC_SUPABASE_ANON_KEY', 'VITE_SUPABASE_ANON_KEY'
  );
  const serviceKey = pick('SUPABASE_SECRET_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_SERVICE_KEY');

  // روابط قاعدة البيانات بالترتيب (الأول الذي يتصل يُستخدم للتهيئة التلقائية)
  const dbUrls = [...new Set([
    pick('SUPABASE_DB_URL'),
    pick('POSTGRES_URL_NON_POOLING'),
    pick('DATABASE_URL'),
    pick('POSTGRES_URL'),
  ].filter(Boolean))];

  const prodHost = pick('VERCEL_PROJECT_PRODUCTION_URL');
  const siteUrl = (pick('SITE_URL') || (prodHost ? `https://${prodHost}` : '')).replace(/\/+$/, '');

  const gmailUser = pick('GMAIL_USER');
  const smtp = {
    host: pick('SMTP_HOST') || (gmailUser ? 'smtp.gmail.com' : ''),
    port: Number(pick('SMTP_PORT') || 465),
    user: pick('SMTP_USER') || gmailUser,
    pass: pick('SMTP_PASS', 'GMAIL_APP_PASSWORD').replace(/\s+/g, ''),
    from: pick('SMTP_FROM'),
  };
  smtp.configured = Boolean(smtp.host && smtp.user && smtp.pass);

  return { url, anonKey, serviceKey, dbUrls, siteUrl, smtp };
}
