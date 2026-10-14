-- =====================================================================
--  مسار | Masar — نظام متابعة الشركات
--  مكتب الطيب للمحاماة والاستشارات القانونية
--
--  قاعدة البيانات (Supabase / PostgreSQL)
--  • آمن للتشغيل أكثر من مرة: لا يحذف بيانات ولا يكرر الإدخالات.
--  • يُشغَّل تلقائياً أثناء النشر على Vercel (إذا توفّر رابط قاعدة البيانات)،
--    أو يدوياً: انسخ الملف كاملاً في Supabase ← SQL Editor ← Run.
--  • كل الجداول تبدأ بـ crm_ (الشركات) أو re_ (العقارات) حتى لا تتعارض مع أي نظام آخر.
--  • بوابتان: «الشركات» لمكتب المحاماة، و«العقارات» للوساطة العقارية.
--    الفصل بينهما مطبّق هنا في قاعدة البيانات (RLS) وليس في الواجهة فقط.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) الفريق (بوابات الدخول: عصام، نور، ...)
-- ---------------------------------------------------------------------
create table if not exists public.crm_team (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid unique references auth.users(id) on delete set null,
  email       text not null unique,
  full_name   text not null,
  name_en     text,
  title_ar    text,
  title_en    text,
  phone       text,
  role        text not null default 'member' check (role in ('admin','partner','member')),
  avatar_url  text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- البوابات المسموحة لكل عضو: companies (الشركات) و/أو realestate (العقارات)
-- المدير يرى البوابتين دائماً. محمد علي مثلاً: {realestate} فقط.
alter table public.crm_team add column if not exists portals text[] not null default '{companies}';
-- نسبة الموظف الافتراضية من عمولة صفقات العقارات (تُقترح عند تسجيل الصفقة)
alter table public.crm_team add column if not exists re_agent_pct numeric(5,2);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'crm_team_portals_check') then
    alter table public.crm_team add constraint crm_team_portals_check
      check (portals <@ array['companies','realestate']::text[]);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'crm_team_re_agent_pct_check') then
    alter table public.crm_team add constraint crm_team_re_agent_pct_check
      check (re_agent_pct is null or (re_agent_pct >= 0 and re_agent_pct <= 100));
  end if;
end $$;

-- دوال مساعدة للصلاحيات (تعمل بصلاحية المالك لتجنّب التكرار في سياسات RLS)
create or replace function public.crm_my_team_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.crm_team where user_id = auth.uid() and active limit 1
$$;

create or replace function public.crm_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.crm_team where user_id = auth.uid() and active)
$$;

create or replace function public.crm_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.crm_team where user_id = auth.uid() and active and role = 'admin')
$$;

-- هل يملك المستخدم الحالي هذه البوابة؟ ('companies' أو 'realestate')
create or replace function public.crm_can(p_portal text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.crm_team
                 where user_id = auth.uid() and active
                   and (role = 'admin' or p_portal = any(portals)))
$$;

-- ---------------------------------------------------------------------
-- 2) الإعدادات (صف واحد)
-- ---------------------------------------------------------------------
create table if not exists public.crm_settings (
  id              smallint primary key default 1 check (id = 1),
  firm_name_ar    text not null default 'مكتب الطيب للمحاماة والاستشارات القانونية',
  firm_name_en    text not null default 'Al-Tayeb Law Firm & Legal Consultants',
  tagline_ar      text not null default 'حيث تصبح الحقوق أكثر من كلمات',
  tagline_en      text not null default 'Where Rights Are More Than Words',
  phone           text default '17225373',
  whatsapp        text default '66335661',
  email           text default 'lawyer.essamaltayeb@gmail.com',
  instagram       text default 'lawyer_essam.altayeb',
  website         text,
  address_ar      text default 'مملكة البحرين، منطقة السيف، برج بيزووتر، طريق 3616، مبنى 742، الطابق 8، مكتب 85',
  address_en      text default 'Kingdom of Bahrain, Seef Area, BayesWater Tower, Road 3616, Building 742, 8th Floor, Office 85',
  maps_url        text,
  profile_url     text default '/assets/altayeb-profile.pdf',
  site_url        text,
  commission_rate numeric(5,2) not null default 30 check (commission_rate >= 0 and commission_rate <= 100),
  partner_id      uuid references public.crm_team(id) on delete set null,
  followup_days   int not null default 3 check (followup_days between 1 and 60),
  country_code    text not null default '973',
  currency        text not null default 'BHD',
  seeded          boolean not null default false,
  schema_version  int not null default 1,
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.crm_team(id) on delete set null
);
insert into public.crm_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3) الزيارات الميدانية
-- ---------------------------------------------------------------------
create table if not exists public.crm_visits (
  id          uuid primary key default gen_random_uuid(),
  visit_date  date not null default current_date,
  area        text,
  title       text,
  notes       text,
  attendees   uuid[] not null default '{}',
  status      text not null default 'done' check (status in ('planned','done')),
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists crm_visits_date_idx on public.crm_visits (visit_date desc);

-- ---------------------------------------------------------------------
-- 4) الشركات / العملاء المحتملون
-- ---------------------------------------------------------------------
create table if not exists public.crm_companies (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  sector          text,
  area            text,
  address         text,
  maps_url        text,
  website         text,
  instagram       text,
  contact_name    text,
  contact_title   text,
  mobile          text,
  phone           text,
  email           text,
  other_contacts  text,
  source          text not null default 'visit',
  visit_id        uuid references public.crm_visits(id) on delete set null,
  stage           text not null default 'visited'
                  check (stage in ('target','visited','contacted','interested','meeting','proposal','won','hold','lost')),
  heat            text not null default 'warm' check (heat in ('hot','warm','cold')),
  owner_id        uuid references public.crm_team(id) on delete set null,
  next_followup   date,
  last_contact_at timestamptz,
  lost_reason     text,
  won_at          date,
  contract_type   text,
  contract_value  numeric(12,3),
  commission_rate numeric(5,2) not null default 30 check (commission_rate >= 0 and commission_rate <= 100),
  notes           text,
  public_token    text not null unique default left(replace(gen_random_uuid()::text, '-', ''), 12),
  link_views      int not null default 0,
  last_view_at    timestamptz,
  created_by      uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists crm_companies_stage_idx    on public.crm_companies (stage);
create index if not exists crm_companies_followup_idx on public.crm_companies (next_followup);
create index if not exists crm_companies_visit_idx    on public.crm_companies (visit_id);
create index if not exists crm_companies_owner_idx    on public.crm_companies (owner_id);

-- صور بطاقات العمل (Business Cards) — تُضغط في المتصفح قبل الحفظ
create table if not exists public.crm_card_images (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.crm_companies(id) on delete cascade,
  data        text not null check (length(data) < 1500000),
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists crm_card_images_company_idx on public.crm_card_images (company_id);

-- ---------------------------------------------------------------------
-- 5) سجل المتابعة (زيارة، واتساب، بريد، اتصال، اجتماع، رد، ملاحظة...)
-- ---------------------------------------------------------------------
create table if not exists public.crm_activities (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.crm_companies(id) on delete cascade,
  type        text not null check (type in ('visit','whatsapp','email','call','meeting','response','note','stage','proposal','payment')),
  body        text,
  outcome     text check (outcome in ('positive','neutral','negative')),
  stage_from  text,
  stage_to    text,
  template_id uuid,
  happened_at timestamptz not null default now(),
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists crm_activities_company_idx on public.crm_activities (company_id, happened_at desc);
create index if not exists crm_activities_recent_idx  on public.crm_activities (created_at desc);

-- ---------------------------------------------------------------------
-- 6) قوالب الخطابات (قابلة للتعديل من بوابة عصام ونور)
-- ---------------------------------------------------------------------
create table if not exists public.crm_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  kind        text not null default 'other' check (kind in ('intro','followup','reminder','meeting','thanks','other')),
  lang        text not null default 'ar' check (lang in ('ar','en','both')),
  channel     text not null default 'both' check (channel in ('whatsapp','email','both')),
  subject     text,
  body        text not null,
  is_default  boolean not null default false,
  sort        int not null default 0,
  updated_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  updated_at  timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7) الأتعاب المحصّلة وعمولة الشريك (30% افتراضياً)
-- ---------------------------------------------------------------------
create table if not exists public.crm_payments (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.crm_companies(id) on delete cascade,
  amount             numeric(12,3) not null check (amount > 0),
  paid_on            date not null default current_date,
  description        text,
  commission_rate    numeric(5,2) not null default 30 check (commission_rate >= 0 and commission_rate <= 100),
  commission_amount  numeric(12,3) generated always as (round(amount * commission_rate / 100, 3)) stored,
  commission_paid    boolean not null default false,
  commission_paid_on date,
  created_by         uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at         timestamptz not null default now()
);
create index if not exists crm_payments_company_idx on public.crm_payments (company_id);

-- ---------------------------------------------------------------------
-- 8) فتح الرابط الخاص بالشركة (هل فتحوا الملف التعريفي؟)
-- ---------------------------------------------------------------------
create table if not exists public.crm_link_events (
  id          bigint generated always as identity primary key,
  company_id  uuid not null references public.crm_companies(id) on delete cascade,
  event       text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index if not exists crm_link_events_company_idx on public.crm_link_events (company_id, created_at desc);
create index if not exists crm_link_events_recent_idx  on public.crm_link_events (created_at desc);

-- =====================================================================
--  بوابة العقارات (الوساطة العقارية) — جداول re_
-- =====================================================================

-- ---------------------------------------------------------------------
-- 9) إعدادات العقارات (صف واحد)
-- ---------------------------------------------------------------------
create table if not exists public.re_settings (
  id                     smallint primary key default 1 check (id = 1),
  brand_name             text not null default 'مكتب الطيب — الوساطة العقارية',
  brand_name_en          text default 'Al-Tayeb Real Estate',
  phone                  text,
  whatsapp               text,
  instagram              text,
  license_no             text,
  sale_commission_pct    numeric(5,2) not null default 2 check (sale_commission_pct >= 0 and sale_commission_pct <= 100),
  rent_commission_months numeric(5,2) not null default 1 check (rent_commission_months >= 0 and rent_commission_months <= 24),
  agent_pct              numeric(5,2) not null default 30 check (agent_pct >= 0 and agent_pct <= 100),
  followup_days          int not null default 2 check (followup_days between 1 and 60),
  share_template         text,
  updated_at             timestamptz not null default now(),
  updated_by             uuid references public.crm_team(id) on delete set null
);
insert into public.re_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 10) الملاك
-- ---------------------------------------------------------------------
create table if not exists public.re_owners (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text,
  whatsapp        text,
  email           text,
  agreement_type  text check (agreement_type in ('exclusive','open','mandate','verbal','other')),
  commission_pct  numeric(5,2) check (commission_pct is null or (commission_pct >= 0 and commission_pct <= 100)),
  agreement_date  date,
  agreement_end   date,
  notes           text,
  agent_id        uuid references public.crm_team(id) on delete set null,
  created_by      uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists re_owners_name_idx on public.re_owners (name);

-- ---------------------------------------------------------------------
-- 11) العقارات
-- ---------------------------------------------------------------------
create sequence if not exists public.re_property_ref_seq start 101;
create table if not exists public.re_properties (
  id            uuid primary key default gen_random_uuid(),
  ref           int not null unique default nextval('public.re_property_ref_seq'),
  title         text,
  category      text not null default 'apartment'
                check (category in ('villa','apartment','house','land','building','shop_office','warehouse','farm','construction','project','other')),
  subtype       text,
  category_other text,
  purpose       text not null default 'sale' check (purpose in ('sale','rent','investment')),
  status        text not null default 'available' check (status in ('available','reserved','sold','rented','off')),
  price         numeric(14,3) check (price is null or price >= 0),
  price_period  text check (price_period in ('month','year')),
  owner_price   numeric(14,3) check (owner_price is null or owner_price >= 0),
  negotiable    boolean not null default true,
  owner_id      uuid references public.re_owners(id) on delete set null,
  agent_id      uuid references public.crm_team(id) on delete set null,
  governorate   text,
  area          text,
  block         text,
  road          text,
  building      text,
  unit          text,
  map_url       text,
  lat           double precision,
  lng           double precision,
  land_area     numeric(12,2) check (land_area is null or land_area >= 0),
  built_area    numeric(12,2) check (built_area is null or built_area >= 0),
  bedrooms      int check (bedrooms is null or bedrooms between 0 and 99),
  bathrooms     int check (bathrooms is null or bathrooms between 0 and 99),
  parking       int check (parking is null or parking between 0 and 999),
  floors        int check (floors is null or floors between 0 and 200),
  age_years     int check (age_years is null or age_years between 0 and 200),
  furnished     text check (furnished in ('furnished','semi','unfurnished')),
  features      text[] not null default '{}',
  video_url     text,
  description   text,
  notes         text,
  status_at     timestamptz,
  created_by    uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter sequence public.re_property_ref_seq owned by public.re_properties.ref;
create index if not exists re_properties_status_idx   on public.re_properties (status);
create index if not exists re_properties_category_idx on public.re_properties (category);
create index if not exists re_properties_owner_idx    on public.re_properties (owner_id);
create index if not exists re_properties_agent_idx    on public.re_properties (agent_id);

-- صور وفيديو العقار (re-media: تظهر للعميل) والمستندات (re-docs: خاصة) في Supabase Storage
create table if not exists public.re_files (
  id          uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.re_properties(id) on delete cascade,
  kind        text not null default 'photo' check (kind in ('photo','video','deed','plan','other')),
  bucket      text not null default 're-media' check (bucket in ('re-media','re-docs')),
  path        text not null,
  thumb_path  text,
  name        text,
  mime        text,
  size        bigint,
  is_public   boolean not null default false,
  sort        int not null default 0,
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists re_files_property_idx on public.re_files (property_id, sort);
-- الصور والفيديو في re-media (عامة) والمستندات في re-docs (خاصة) — لا يمكن تبديل نوع ملف لتجاوز صلاحية الحذف
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 're_files_kind_bucket_check') then
    alter table public.re_files add constraint re_files_kind_bucket_check
      check ((kind in ('photo','video') and bucket = 're-media') or (kind in ('deed','plan','other') and bucket = 're-docs')) not valid;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 12) العملاء وطلباتهم
-- ---------------------------------------------------------------------
create table if not exists public.re_clients (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  phone           text,
  whatsapp        text,
  email           text,
  nationality     text,
  kind            text not null default 'buyer' check (kind in ('buyer','tenant','investor','owner')),
  source          text check (source in ('instagram','whatsapp','call','website','referral','ad','walkin','other')),
  agent_id        uuid references public.crm_team(id) on delete set null,
  status          text not null default 'active' check (status in ('active','won','lost','paused')),
  lead_override   text check (lead_override in ('cold','warm','hot','very_hot')),
  -- طلب العميل (قابل للفلترة والمطابقة)
  want_types      text[] not null default '{}',
  want_purpose    text check (want_purpose in ('buy','rent','invest')),
  budget_min      numeric(14,3) check (budget_min is null or budget_min >= 0),
  budget_max      numeric(14,3) check (budget_max is null or budget_max >= 0),
  want_areas      text[] not null default '{}',
  min_bedrooms    int check (min_bedrooms is null or min_bedrooms between 0 and 99),
  min_bathrooms   int check (min_bathrooms is null or min_bathrooms between 0 and 99),
  min_parking     int check (min_parking is null or min_parking between 0 and 999),
  min_area        numeric(12,2) check (min_area is null or min_area >= 0),
  want_furnished  text check (want_furnished in ('furnished','unfurnished')),
  want_features   text[] not null default '{}',
  request_notes   text,
  -- المتابعة
  first_contact   date not null default current_date,
  next_followup   date,
  followup_note   text,
  last_contact_at timestamptz,
  lost_reason     text,
  notes           text,
  created_by      uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists re_clients_followup_idx on public.re_clients (next_followup);
create index if not exists re_clients_agent_idx    on public.re_clients (agent_id);
create index if not exists re_clients_status_idx   on public.re_clients (status);

-- العقارات المرسلة لكل عميل وردّه عليها (أُرسل / أعجبه / رفضه + السبب / معاينة)
create table if not exists public.re_client_props (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.re_clients(id) on delete cascade,
  property_id uuid not null references public.re_properties(id) on delete cascade,
  status      text not null default 'sent' check (status in ('suggested','sent','liked','rejected','viewing','viewed','offer')),
  reason      text,
  score       int,
  sent_at     timestamptz,
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (client_id, property_id)
);
create index if not exists re_client_props_property_idx on public.re_client_props (property_id);

-- مواعيد المعاينة
create table if not exists public.re_viewings (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.re_clients(id) on delete cascade,
  property_id uuid not null references public.re_properties(id) on delete cascade,
  at          timestamptz not null,
  status      text not null default 'scheduled' check (status in ('scheduled','done','cancelled','no_show')),
  result      text check (result in ('liked','rejected','thinking')),
  notes       text,
  agent_id    uuid references public.crm_team(id) on delete set null,
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists re_viewings_at_idx     on public.re_viewings (at);
create index if not exists re_viewings_client_idx on public.re_viewings (client_id);

-- ---------------------------------------------------------------------
-- 13) الصفقات والعمولات: سعر الصفقة ← العمولة ← نصيب الموظف ← ربح المكتب
-- ---------------------------------------------------------------------
create table if not exists public.re_deals (
  id                  uuid primary key default gen_random_uuid(),
  property_id         uuid references public.re_properties(id) on delete set null,
  client_id           uuid references public.re_clients(id) on delete set null,
  owner_id            uuid references public.re_owners(id) on delete set null,
  agent_id            uuid references public.crm_team(id) on delete set null,
  kind                text not null default 'sale' check (kind in ('sale','rent')),
  title               text,
  price               numeric(14,3) not null default 0 check (price >= 0),
  price_period        text check (price_period in ('month','year')),   -- للإيجار: شهري أو سنوي
  commission          numeric(14,3) not null default 0 check (commission >= 0),
  agent_pct           numeric(5,2) not null default 0 check (agent_pct >= 0 and agent_pct <= 100),
  agent_amount        numeric(14,3) generated always as (round(commission * agent_pct / 100, 3)) stored,
  office_amount       numeric(14,3) generated always as (commission - round(commission * agent_pct / 100, 3)) stored,
  deal_date           date not null default current_date,
  payment_method      text check (payment_method in ('cash','transfer','cheque','installments','mortgage','other')),
  status              text not null default 'negotiation' check (status in ('negotiation','reserved','completed','cancelled')),
  commission_received boolean not null default false,
  agent_paid          boolean not null default false,
  agent_paid_on       date,
  notes               text,
  created_by          uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
alter table public.re_deals add column if not exists price_period text check (price_period in ('month','year'));
create index if not exists re_deals_date_idx   on public.re_deals (deal_date desc);
create index if not exists re_deals_status_idx on public.re_deals (status);

-- ---------------------------------------------------------------------
-- 14) سجل متابعة العميل (Customer Timeline) والعقار والمالك
-- ---------------------------------------------------------------------
create table if not exists public.re_activities (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid references public.re_clients(id) on delete cascade,
  property_id uuid references public.re_properties(id) on delete cascade,
  owner_id    uuid references public.re_owners(id) on delete cascade,
  deal_id     uuid references public.re_deals(id) on delete set null,
  type        text not null check (type in ('created','note','call','whatsapp','email','sent','opened','liked','rejected','viewing','viewed','status','deal','followup','meeting')),
  body        text,
  meta        jsonb not null default '{}'::jsonb,
  happened_at timestamptz not null default now(),
  created_by  uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists re_activities_client_idx   on public.re_activities (client_id, happened_at desc);
create index if not exists re_activities_property_idx on public.re_activities (property_id, happened_at desc);
create index if not exists re_activities_owner_idx    on public.re_activities (owner_id, happened_at desc);
create index if not exists re_activities_recent_idx   on public.re_activities (happened_at desc);

-- روابط القوائم المرسلة للعملاء (/r/رمز) — تُقرأ عبر /api/re-share فقط
create table if not exists public.re_shares (
  id           uuid primary key default gen_random_uuid(),
  token        text not null unique default left(replace(gen_random_uuid()::text, '-', ''), 14)
               check (token ~ '^[a-z0-9]{10,40}$'),
  client_id    uuid references public.re_clients(id) on delete cascade,
  property_ids uuid[] not null default '{}',
  views        int not null default 0,
  last_view_at timestamptz,
  revoked      boolean not null default false,
  created_by   uuid default public.crm_my_team_id() references public.crm_team(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists re_shares_client_idx on public.re_shares (client_id);

-- =====================================================================
-- المشغّلات (Triggers)
-- =====================================================================

-- تحديث updated_at عند أي تعديل حقيقي على الشركة (وليس عند فتح الرابط فقط)
-- + تاريخ التوكيل تلقائياً
create or replace function public.crm_companies_before_update() returns trigger
language plpgsql as $$
begin
  if (to_jsonb(new) - 'link_views' - 'last_view_at' - 'updated_at')
     is distinct from (to_jsonb(old) - 'link_views' - 'last_view_at' - 'updated_at') then
    new.updated_at := now();
  end if;
  if new.stage = 'won' and old.stage is distinct from 'won' and new.won_at is null then
    new.won_at := current_date;
  end if;
  return new;
end $$;
drop trigger if exists crm_companies_before_update on public.crm_companies;
create trigger crm_companies_before_update before update on public.crm_companies
  for each row execute function public.crm_companies_before_update();

-- نسبة العمولة على الشركة يحددها المدير فقط (الشريكة ترى عمولتها ولا تغيّرها)
create or replace function public.crm_companies_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.crm_is_admin() then
    if tg_op = 'INSERT' then
      new.commission_rate := coalesce((select commission_rate from public.crm_settings where id = 1), 30);
    elsif new.commission_rate is distinct from old.commission_rate then
      raise exception 'غير مسموح: نسبة العمولة يحددها المدير فقط';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists crm_companies_guard on public.crm_companies;
create trigger crm_companies_guard before insert or update on public.crm_companies
  for each row execute function public.crm_companies_guard();

-- تسجيل تغيير المرحلة في سجل المتابعة تلقائياً
create or replace function public.crm_companies_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage is distinct from old.stage then
    insert into public.crm_activities (company_id, type, stage_from, stage_to, created_by)
    values (new.id, 'stage', old.stage, new.stage, public.crm_my_team_id());
  end if;
  return null;
end $$;
drop trigger if exists crm_companies_after_update on public.crm_companies;
create trigger crm_companies_after_update after update on public.crm_companies
  for each row execute function public.crm_companies_after_update();

-- تسجيل الدفعة في سجل المتابعة
create or replace function public.crm_payments_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.crm_activities (company_id, type, body, created_by)
  values (new.company_id, 'payment',
          'تحصيل أتعاب: ' || to_char(new.amount, 'FM999999990.000') || coalesce(' — ' || nullif(new.description, ''), ''),
          public.crm_my_team_id());
  return null;
end $$;
drop trigger if exists crm_payments_after_insert on public.crm_payments;
create trigger crm_payments_after_insert after insert on public.crm_payments
  for each row execute function public.crm_payments_after_insert();

-- من عدّل القالب ومتى
create or replace function public.crm_touch_editor() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(public.crm_my_team_id(), new.updated_by);
  return new;
end $$;
drop trigger if exists crm_templates_touch on public.crm_templates;
create trigger crm_templates_touch before update on public.crm_templates
  for each row execute function public.crm_touch_editor();
drop trigger if exists crm_settings_touch on public.crm_settings;
create trigger crm_settings_touch before update on public.crm_settings
  for each row execute function public.crm_touch_editor();

-- لا يستطيع غير المدير تغيير صلاحيته أو بريده أو تعطيل نفسه
create or replace function public.crm_team_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.crm_is_admin() then
    if new.role is distinct from old.role
       or new.active is distinct from old.active
       or new.email is distinct from old.email
       or new.user_id is distinct from old.user_id
       or new.portals is distinct from old.portals
       or new.re_agent_pct is distinct from old.re_agent_pct then
      raise exception 'غير مسموح: هذا التعديل للمدير فقط';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists crm_team_guard on public.crm_team;
create trigger crm_team_guard before update on public.crm_team
  for each row execute function public.crm_team_guard();

-- العقارات: تاريخ آخر تعديل
create or replace function public.re_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
-- العقار: + تاريخ تغيّر الحالة
create or replace function public.re_properties_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if new.status is distinct from old.status then
    new.status_at := now();
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['re_owners','re_clients','re_client_props','re_viewings'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_touch', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.re_touch()', t || '_touch', t);
  end loop;
end $$;
drop trigger if exists re_properties_touch on public.re_properties;
create trigger re_properties_touch before update on public.re_properties
  for each row execute function public.re_properties_touch();
drop trigger if exists re_settings_touch on public.re_settings;
create trigger re_settings_touch before update on public.re_settings
  for each row execute function public.crm_touch_editor();

-- ملفات العقار: غير المدير لا يغيّر نوع الملف أو مكانه أو ظهوره (يعدّل الترتيب فقط)
create or replace function public.re_files_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.crm_is_admin() then
    if tg_op = 'INSERT' then
      new.is_public := new.kind in ('photo','video');
    elsif new.kind is distinct from old.kind or new.bucket is distinct from old.bucket
       or new.path is distinct from old.path or new.thumb_path is distinct from old.thumb_path
       or new.property_id is distinct from old.property_id or new.is_public is distinct from old.is_public then
      raise exception 'غير مسموح: تعديل الملف للمدير فقط';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists re_files_guard on public.re_files;
create trigger re_files_guard before insert or update on public.re_files
  for each row execute function public.re_files_guard();

-- الصفقات: نسبة الموظف وصرف نصيبه للمدير فقط، والصفقة المكتملة أو المصروفة لا يعدّلها إلا المدير
create or replace function public.re_deals_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_default numeric; v_old_default numeric;
begin
  if auth.uid() is not null and not public.crm_is_admin() then
    select coalesce(t.re_agent_pct, s.agent_pct, 0) into v_default
      from public.re_settings s left join public.crm_team t on t.id = new.agent_id
     where s.id = 1;
    if tg_op = 'INSERT' then
      new.agent_pct := coalesce(v_default, 0);
      new.agent_paid := false;
      new.agent_paid_on := null;
    else
      -- الصفقة المكتملة أو المصروفة عمولتها: الملاحظات واستلام العمولة فقط
      if old.status = 'completed' or old.agent_paid then
        if (to_jsonb(new) - array['notes','commission_received','updated_at','agent_amount','office_amount'])
           is distinct from (to_jsonb(old) - array['notes','commission_received','updated_at','agent_amount','office_amount']) then
          raise exception 'غير مسموح: الصفقة مكتملة — تعديلها للمدير فقط';
        end if;
      end if;
      if new.agent_paid is distinct from old.agent_paid or new.agent_paid_on is distinct from old.agent_paid_on then
        raise exception 'غير مسموح: صرف عمولة الموظف للمدير فقط';
      end if;
      if new.agent_id is distinct from old.agent_id then
        -- نسبة خاصة حددها المدير لهذه الصفقة لا يلغيها تغيير الموظف
        select coalesce(t.re_agent_pct, s.agent_pct, 0) into v_old_default
          from public.re_settings s left join public.crm_team t on t.id = old.agent_id
         where s.id = 1;
        if old.agent_pct is distinct from coalesce(v_old_default, 0) then
          raise exception 'غير مسموح: نسبة الموظف في هذه الصفقة حددها المدير — تغيير الموظف للمدير فقط';
        end if;
        new.agent_pct := coalesce(v_default, 0);   -- تغيير الموظف = نسبته هو
      elsif new.agent_pct is distinct from old.agent_pct then
        raise exception 'غير مسموح: نسبة الموظف للمدير فقط';
      end if;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end $$;
drop trigger if exists re_deals_guard on public.re_deals;
create trigger re_deals_guard before insert or update on public.re_deals
  for each row execute function public.re_deals_guard();

-- =====================================================================
-- الحماية (Row Level Security): البيانات لأعضاء الفريق فقط
-- =====================================================================
alter table public.crm_team        enable row level security;
alter table public.crm_settings    enable row level security;
alter table public.crm_visits      enable row level security;
alter table public.crm_companies   enable row level security;
alter table public.crm_card_images enable row level security;
alter table public.crm_activities  enable row level security;
alter table public.crm_templates   enable row level security;
alter table public.crm_payments    enable row level security;
alter table public.crm_link_events enable row level security;
alter table public.re_settings     enable row level security;
alter table public.re_owners       enable row level security;
alter table public.re_properties   enable row level security;
alter table public.re_files        enable row level security;
alter table public.re_clients      enable row level security;
alter table public.re_client_props enable row level security;
alter table public.re_viewings     enable row level security;
alter table public.re_deals        enable row level security;
alter table public.re_activities   enable row level security;
alter table public.re_shares       enable row level security;

-- إعادة إنشاء السياسات من جديد في كل تشغيل
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and (tablename like 'crm\_%' or tablename like 're\_%') loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- الفريق: الجميع يرى، المدير يدير، وكل عضو يعدّل بياناته الشخصية
create policy crm_team_read   on public.crm_team for select to authenticated using ((select public.crm_is_member()));
create policy crm_team_admin  on public.crm_team for all    to authenticated using ((select public.crm_is_admin())) with check ((select public.crm_is_admin()));
create policy crm_team_self   on public.crm_team for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ---------------- بوابة الشركات (مكتب المحاماة) ----------------
-- لا يصل إليها إلا من يملك بوابة «الشركات» (عصام ونور) — محمد علي لا يرى منها شيئاً
create policy crm_settings_read  on public.crm_settings for select to authenticated using ((select public.crm_can('companies')));
create policy crm_settings_admin on public.crm_settings for update to authenticated using ((select public.crm_is_admin())) with check ((select public.crm_is_admin()));

create policy crm_visits_all      on public.crm_visits      for all to authenticated using ((select public.crm_can('companies'))) with check ((select public.crm_can('companies')));
create policy crm_companies_all   on public.crm_companies   for all to authenticated using ((select public.crm_can('companies'))) with check ((select public.crm_can('companies')));
create policy crm_card_images_all on public.crm_card_images for all to authenticated using ((select public.crm_can('companies'))) with check ((select public.crm_can('companies')));
create policy crm_activities_all  on public.crm_activities  for all to authenticated using ((select public.crm_can('companies'))) with check ((select public.crm_can('companies')));
create policy crm_templates_all   on public.crm_templates   for all to authenticated using ((select public.crm_can('companies'))) with check ((select public.crm_can('companies')));

-- الأتعاب والعمولات: أعضاء بوابة الشركات يرون، المدير فقط يسجّل ويصرف
create policy crm_payments_read  on public.crm_payments for select to authenticated using ((select public.crm_can('companies')));
create policy crm_payments_admin on public.crm_payments for all    to authenticated using ((select public.crm_is_admin())) with check ((select public.crm_is_admin()));

-- فتح الرابط: يُسجَّل عبر دالة عامة فقط، والفريق يقرأ
create policy crm_link_events_read   on public.crm_link_events for select to authenticated using ((select public.crm_can('companies')));
create policy crm_link_events_delete on public.crm_link_events for delete to authenticated using ((select public.crm_can('companies')));

-- ---------------- بوابة العقارات (الوساطة العقارية) ----------------
-- لمن يملك بوابة «العقارات» (عصام ونور ومحمد). الحذف النهائي للمدير فقط.
create policy re_settings_read  on public.re_settings for select to authenticated using ((select public.crm_can('realestate')));
create policy re_settings_admin on public.re_settings for update to authenticated using ((select public.crm_is_admin())) with check ((select public.crm_is_admin()));

do $$
declare t text;
begin
  foreach t in array array['re_owners','re_properties','re_clients','re_deals'] loop
    execute format('create policy %I on public.%I for select to authenticated using ((select public.crm_can(''realestate'')))', t || '_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.crm_can(''realestate'')))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.crm_can(''realestate''))) with check ((select public.crm_can(''realestate'')))', t || '_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.crm_is_admin()))', t || '_delete', t);
  end loop;
  -- المعاينات وردود العملاء: قراءة وإضافة وتعديل، والحذف للمدير
  foreach t in array array['re_client_props','re_viewings','re_files'] loop
    execute format('create policy %I on public.%I for select to authenticated using ((select public.crm_can(''realestate'')))', t || '_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.crm_can(''realestate'')))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.crm_can(''realestate''))) with check ((select public.crm_can(''realestate'')))', t || '_update', t);
  end loop;
  -- السجل وروابط القوائم: إضافة فقط (لا تعديل ولا حذف للتاريخ إلا من المدير)
  foreach t in array array['re_activities','re_shares'] loop
    execute format('create policy %I on public.%I for select to authenticated using ((select public.crm_can(''realestate'')))', t || '_read', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.crm_can(''realestate'')))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.crm_is_admin())) with check ((select public.crm_is_admin()))', t || '_update', t);
  end loop;
  foreach t in array array['re_client_props','re_viewings','re_activities','re_shares'] loop
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.crm_is_admin()))', t || '_delete', t);
  end loop;
end $$;
-- الصور والفيديو يحذفها أي موظف عقارات، والمستندات (وثيقة الملكية...) المدير فقط
create policy re_files_delete on public.re_files for delete to authenticated
  using ((select public.crm_is_admin()) or ((select public.crm_can('realestate')) and kind in ('photo','video')));

-- الصلاحيات على مستوى الجداول (لا شيء للزوار المجهولين)
revoke all on public.crm_team, public.crm_settings, public.crm_visits, public.crm_companies,
              public.crm_card_images, public.crm_activities, public.crm_templates,
              public.crm_payments, public.crm_link_events from anon;
grant select, insert, update, delete on public.crm_team, public.crm_settings, public.crm_visits,
              public.crm_companies, public.crm_card_images, public.crm_activities,
              public.crm_templates, public.crm_payments, public.crm_link_events to authenticated;
grant all on public.crm_team, public.crm_settings, public.crm_visits, public.crm_companies,
             public.crm_card_images, public.crm_activities, public.crm_templates,
             public.crm_payments, public.crm_link_events to service_role;
grant usage, select on sequence public.crm_link_events_id_seq to authenticated, service_role;

revoke all on public.re_settings, public.re_owners, public.re_properties, public.re_files,
              public.re_clients, public.re_client_props, public.re_viewings, public.re_deals,
              public.re_activities, public.re_shares from anon;
grant select, insert, update, delete on public.re_settings, public.re_owners, public.re_properties,
              public.re_files, public.re_clients, public.re_client_props, public.re_viewings,
              public.re_deals, public.re_activities, public.re_shares to authenticated;
grant all on public.re_settings, public.re_owners, public.re_properties, public.re_files,
             public.re_clients, public.re_client_props, public.re_viewings, public.re_deals,
             public.re_activities, public.re_shares to service_role;
grant usage, select on sequence public.re_property_ref_seq to authenticated, service_role;

-- =====================================================================
-- دوال عامة (RPC)
-- =====================================================================

-- حالة النظام (هل تم الإعداد؟)
create or replace function public.crm_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true,
    'has_admin', exists (select 1 from public.crm_team where role = 'admin' and active),
    'version', (select schema_version from public.crm_settings where id = 1)
  )
$$;

-- بيانات المستخدم الحالي
create or replace function public.crm_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(t) from public.crm_team t where t.user_id = auth.uid() and t.active limit 1
$$;

-- بيانات الصفحة الخاصة بالشركة (الرابط المرسل) — لا تكشف إلا الاسم وبيانات التواصل
create or replace function public.crm_public_page(p_token text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_company public.crm_companies%rowtype;
  v_owner   public.crm_team%rowtype;
  v_set     public.crm_settings%rowtype;
  v_team    jsonb;
begin
  select * into v_set from public.crm_settings where id = 1;
  if p_token is not null and length(p_token) between 6 and 64 then
    select * into v_company from public.crm_companies where public_token = p_token;
  end if;
  if v_company.id is not null and v_company.owner_id is not null then
    select * into v_owner from public.crm_team where id = v_company.owner_id and active;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', t.full_name, 'name_en', t.name_en, 'title_ar', t.title_ar, 'title_en', t.title_en,
           'phone', t.phone, 'avatar', t.avatar_url, 'role', t.role)
           order by case t.role when 'admin' then 0 when 'partner' then 1 else 2 end, t.created_at), '[]'::jsonb)
    into v_team
    from public.crm_team t where t.active and t.role in ('admin','partner');
  return jsonb_build_object(
    'company', case when v_company.id is null then null
               else jsonb_build_object('name', v_company.name, 'contact', v_company.contact_name) end,
    'owner',   case when v_owner.id is null then null
               else jsonb_build_object('name', v_owner.full_name, 'name_en', v_owner.name_en,
                                       'title_ar', v_owner.title_ar, 'title_en', v_owner.title_en,
                                       'phone', v_owner.phone, 'avatar', v_owner.avatar_url) end,
    'team', v_team,
    'firm', jsonb_build_object(
      'name_ar', v_set.firm_name_ar, 'name_en', v_set.firm_name_en,
      'tagline_ar', v_set.tagline_ar, 'tagline_en', v_set.tagline_en,
      'phone', v_set.phone, 'whatsapp', v_set.whatsapp, 'email', v_set.email,
      'instagram', v_set.instagram, 'website', v_set.website,
      'address_ar', v_set.address_ar, 'address_en', v_set.address_en,
      'maps_url', v_set.maps_url, 'profile_url', v_set.profile_url,
      'country_code', v_set.country_code)
  );
end $$;

-- تسجيل فتح الرابط/الضغط على الأزرار (مع منع التكرار خلال 20 دقيقة)
create or replace function public.crm_track(p_token text, p_event text, p_ua text default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_event is null or p_event not in ('open','pdf','pages','whatsapp','call','email','instagram','meeting','map') then
    return;
  end if;
  select id into v_id from public.crm_companies where public_token = p_token;
  if v_id is null then return; end if;
  if exists (select 1 from public.crm_link_events
             where company_id = v_id and event = p_event and created_at > now() - interval '20 minutes') then
    return;
  end if;
  insert into public.crm_link_events (company_id, event, user_agent) values (v_id, p_event, left(p_ua, 300));
  if p_event = 'open' then
    update public.crm_companies set link_views = link_views + 1, last_view_at = now() where id = v_id;
  end if;
end $$;

revoke all on function public.crm_status()                    from public;
revoke all on function public.crm_me()                        from public;
revoke all on function public.crm_public_page(text)           from public;
revoke all on function public.crm_track(text, text, text)     from public;
grant execute on function public.crm_status()                 to anon, authenticated, service_role;
grant execute on function public.crm_me()                     to authenticated, service_role;
grant execute on function public.crm_public_page(text)        to anon, authenticated, service_role;
grant execute on function public.crm_track(text, text, text)  to anon, authenticated, service_role;
grant execute on function public.crm_my_team_id()             to authenticated, service_role;
grant execute on function public.crm_is_member()              to anon, authenticated, service_role;
grant execute on function public.crm_is_admin()               to anon, authenticated, service_role;
grant execute on function public.crm_can(text)                to anon, authenticated, service_role;

-- =====================================================================
-- البيانات الأولية
-- =====================================================================

-- قوالب الخطابات (تُضاف مرة واحدة فقط — تعديلاتكم لا تُستبدل)
insert into public.crm_templates (name, kind, lang, channel, subject, body, is_default, sort)
select v.name, v.kind, v.lang, v.channel, v.subject, v.body, v.is_default, v.sort
from (values
(
  'الخطاب التعريفي (عربي + English)', 'intro', 'both', 'both',
  'Al-Tayeb Law Firm | مكتب الطيب للمحاماة والاستشارات القانونية',
$tpl$*« حيث تصبح الحقوق أكثر من كلمات »*

السادة / {الشركة} المحترمين،

يسرنا التواصل معكم من مكتب الطيب للمحاماة والإستشارات القانونية، ونقدّر الدور المميز الذي تقوم به شركتكم في مجالها التي تعكس احترافية عالية ورؤية واضحة.
وانطلاقاً من خبرتنا نؤمن أن العمل القانوني لا يقتصر على تقديم الاستشارات فقط، بل يقوم على بناء علاقة قائمة على الفهم والدعم الحقيقي بما يساعد على حماية الأعمال وتسهيل نموها بثقة واستقرار.
يسعدنا أن نلتقي بكم (حضورياً أو عبر الاتصال المرئي) لنتعرف بشكل أفضل على احتياجاتكم القانونية ونبحث سبل التعاون بما يحقق قيمة حقيقية مضافة لأعمالكم.
- تجدون أدناه نبذة تعريفية عن المكتب للاطلاع، آملين أن تنال اهتمامكم.
شاكرين لكم وقتكم، ونتطلع إلى فرصة اللقاء بكم قريباً.

*“ Where Rights Are More Than Words ”*

Dear {الشركة} Team,

We are pleased to reach out to you on behalf of Al-Tayeb Law Firm and Legal Consultancy. We hold in high regard the distinguished position your company occupies within its industry, reflecting a strong sense of professionalism and a clear strategic vision.
Based on our experience, we believe that legal services extend far beyond providing advice; they are rooted in building trusted relationships founded on understanding and genuine support. This enables businesses to operate securely while fostering sustainable growth with confidence and stability.
We would be delighted to arrange a meeting with you—either in person or via video conference—to gain a deeper understanding of your legal needs and to explore avenues for collaboration that deliver meaningful added value to your business.
Please find a brief profile of our firm below for your kind review. We hope it will be of interest to you.
Thank you for your time and consideration. We look forward to the opportunity of meeting with you in the near future.

📎 الملف التعريفي | Company Profile:
{رابط_الملف}

Kind regards,
{المرسل} | {المرسل_EN}
{الصفة} | {الصفة_EN}
مكتب الطيب للمحاماة والاستشارات القانونية
📞 {هاتف_المرسل}
📷 Instagram: {انستغرام}$tpl$,
  true, 1
),
(
  'متابعة سريعة بعد الزيارة', 'followup', 'ar', 'whatsapp', null,
$tpl$مرحباً {المسؤول} 👋
معكم {المرسل} من مكتب الطيب للمحاماة والاستشارات القانونية.
سعدنا بزيارتكم في {الشركة}، وكما وعدناكم هذا الملف التعريفي للمكتب وفريق العمل والخدمات التي نقدمها:
{رابط_الملف}

يسعدنا ترتيب لقاء قصير في الوقت الذي يناسبكم 🤝
📷 {انستغرام}$tpl$,
  false, 2
),
(
  'تذكير لطيف', 'reminder', 'ar', 'both',
  'متابعة — مكتب الطيب للمحاماة والاستشارات القانونية',
$tpl$مرحباً {المسؤول}،
أتمنى أن تكونوا بخير. نود التأكد من وصول رسالتنا السابقة والملف التعريفي لمكتب الطيب للمحاماة والاستشارات القانونية.
يسعدنا ترتيب لقاء قصير (حضورياً أو عبر الاتصال المرئي) في الوقت الذي يناسبكم لمناقشة احتياجات {الشركة} القانونية.

الملف التعريفي: {رابط_الملف}

مع خالص التحية،
{المرسل}
{هاتف_المرسل}$tpl$,
  false, 3
),
(
  'Follow-up (English)', 'followup', 'en', 'both',
  'Al-Tayeb Law Firm — Following up with {الشركة}',
$tpl$Dear {المسؤول},

I hope this message finds you well. Following our recent visit to {الشركة}, I wanted to make sure you received our firm's profile:
{رابط_الملف}

We would be glad to arrange a short meeting — in person or via video call — at a time that suits you.

Kind regards,
{المرسل_EN}
{الصفة_EN} — Al-Tayeb Law Firm & Legal Consultants
{هاتف_المرسل}$tpl$,
  false, 4
),
(
  'تأكيد موعد الاجتماع', 'meeting', 'ar', 'both',
  'تأكيد موعد اللقاء — مكتب الطيب للمحاماة',
$tpl$السادة / {الشركة} المحترمين،
نشكركم على تجاوبكم، ويسعدنا تأكيد موعد اللقاء:
📅 التاريخ: ____
🕐 الوقت: ____
📍 المكان: مقر المكتب — منطقة السيف / عبر الاتصال المرئي

للتواصل المباشر: {هاتف_المرسل}
{المرسل} — مكتب الطيب للمحاماة والاستشارات القانونية$tpl$,
  false, 5
),
(
  'شكر بعد الاجتماع', 'thanks', 'ar', 'both',
  'شكراً لوقتكم — مكتب الطيب للمحاماة',
$tpl$السادة / {الشركة} المحترمين،
نشكركم على وقتكم وحسن استقبالكم خلال لقائنا، وسعدنا بالتعرف أكثر على أعمالكم.
كما اتفقنا، سنوافيكم بعرض الخدمات القانونية المقترح خلال الأيام القادمة.
نتطلع إلى شراكة ناجحة بإذن الله.

{المرسل}
مكتب الطيب للمحاماة والاستشارات القانونية
{هاتف_المرسل}$tpl$,
  false, 6
)
) as v(name, kind, lang, channel, subject, body, is_default, sort)
where not exists (select 1 from public.crm_templates);

-- الشركات التي تمت زيارتها من ملف المتابعة (Excel) — تُضاف مرة واحدة فقط عند أول تشغيل
do $$
begin
  if (select seeded from public.crm_settings where id = 1) or exists (select 1 from public.crm_companies) then
    update public.crm_settings set seeded = true where id = 1 and not seeded;
    return;
  end if;

  with v as (
    insert into public.crm_visits (visit_date, title, notes, status)
    values ('2026-09-27', 'جولة 27 سبتمبر', 'مستوردة من ملف المتابعة (Excel)', 'done'),
           ('2026-09-28', 'جولة 28 سبتمبر', 'مستوردة من ملف المتابعة (Excel)', 'done'),
           ('2026-09-29', 'جولة 29 سبتمبر', 'مستوردة من ملف المتابعة (Excel)', 'done')
    returning id, visit_date
  ),
  src (name, contact, email, vdate, resend) as (
    values
      ('ADEX',               'عباس يوسف',               'abbas@adexgroups.com',             date '2026-09-27', date '2026-10-11'),
      ('Al-Saraya',          'حسام محمد تهامي',          'info@alsarayabahrain.bh',          date '2026-09-27', null::date),
      ('MM Brand',           'احمد (a.rahim)',           'a.rahim@mm-brand.com',             date '2026-09-27', null::date),
      ('Aegis',              'Anoop',                    'anoop@eagisinsurancebrokers.com',  date '2026-09-27', null::date),
      ('Masader Gulf',       'Ahmed Al Alami',           'a.alami@masadergulf.com',          date '2026-09-28', null::date),
      ('Inter Gulf',         'سارة عيسى الراشد',         'sara.alrashed@intergulfib.com',    date '2026-09-28', null::date),
      ('Orient',             'عيسى مبارك',               'isa.mubarak@alfuttaim.com',        date '2026-09-29', date '2026-10-11'),
      ('Al Matrook',         'السادة / مكتب المتروك',    'info@al-matrook.com',              date '2026-09-29', date '2026-10-11'),
      ('Yellow Door Energy', 'سارة العلوي',              'sara.alalawi@yellowdoorenergy.com', date '2026-09-29', date '2026-10-11'),
      ('KC Real Estate',     'محمد يوسف',                'kcrealbh@gmail.com',               null::date,        null::date),
      ('Energy Capital',     null,                       'maria.menezes@ecgsaudi.com',       null::date,        null::date),
      ('BR Interiors',       null,                       'christie.r@brinteriorsbh.com',     null::date,        null::date)
  ),
  ins as (
    insert into public.crm_companies (name, contact_name, email, visit_id, stage, next_followup, last_contact_at, notes, source)
    select s.name, s.contact, s.email, v.id,
           case when s.resend is not null then 'contacted' else 'visited' end,
           case when s.resend is not null then s.resend + 3 else current_date end,
           case when s.resend is not null then (s.resend + time '12:00') at time zone 'Asia/Bahrain' end,
           case when s.vdate is null then 'من ملف المتابعة — تاريخ الزيارة غير مسجّل' end,
           'visit'
    from src s left join v on v.visit_date = s.vdate
    returning id, name
  )
  insert into public.crm_activities (company_id, type, body, happened_at)
  select ins.id, 'visit', 'زيارة ميدانية واستلام بطاقة العمل (من ملف المتابعة)',
         (s.vdate + time '11:00') at time zone 'Asia/Bahrain'
    from ins join src s on s.name = ins.name where s.vdate is not null
  union all
  select ins.id, 'email', 'إعادة إرسال الخطاب التعريفي بالبريد (من ملف المتابعة)',
         (s.resend + time '12:00') at time zone 'Asia/Bahrain'
    from ins join src s on s.name = ins.name where s.resend is not null
  union all
  select ins.id, 'note', 'أُضيفت من ملف المتابعة — تاريخ الزيارة غير مسجّل',
         now()
    from ins join src s on s.name = ins.name where s.vdate is null;

  update public.crm_settings set seeded = true where id = 1;
end $$;

-- الترقية إلى الإصدار 2 (بوابة العقارات): المدير والشريك يحصلان على البوابتين
do $$
begin
  if (select schema_version from public.crm_settings where id = 1) < 2 then
    update public.crm_team
       set portals = array['companies','realestate']
     where role in ('admin','partner') and not ('realestate' = any(portals));
  end if;
end $$;

-- إصدار قاعدة البيانات
update public.crm_settings set schema_version = 2 where id = 1 and schema_version < 2;

-- إعادة تحميل الذاكرة المؤقتة لواجهة Supabase API
notify pgrst, 'reload schema';
