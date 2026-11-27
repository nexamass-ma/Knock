-- KNOCK Business: business accounts on the shared Knock infrastructure.
-- ---------------------------------------------------------------------------
-- Design: a business is an ACCOUNT HOLDER, exactly like a person.
--
--   knock.profiles gains `kind` ('person' | 'business'). Every business has one
--   profile row (its handle, display name, status and tier) plus a
--   knock.businesses row with the business details. Because the existing
--   engines (ledger, Payment Links, Smart Split, Breet deposits, withdrawals,
--   settlement, notifications, risk) all key money by profile id, a business
--   automatically gets:
--     * its own ledger accounts (user_available, user_pending, ... with
--       owner_id = business id) in the ONE ledger: no second wallet system;
--     * its own payment links, deposits, addresses, withdrawals, settlements;
--     * the same idempotency, ordering and balance rules, with no copy of any
--       money-moving function.
--   People act for a business through knock.business_members. Every business
--   function checks the member's permission in the database first.
--
--   A business profile is never an auth user, so it can never sign in. Its
--   status and tier are derived from business verification (trigger below),
--   so the engines' own "status = active" and "kyc_tier >= 1" checks block
--   unverified or restricted businesses from links, deposits and payouts.
--
-- Additive only: nothing is dropped except the profiles -> auth.users FK,
-- which is replaced by an equivalent check that applies to people only.
-- ---------------------------------------------------------------------------
set search_path = knock, public;

-- ---------------------------------------------------------------------------
-- 0. Profiles become account holders (person | business)
-- ---------------------------------------------------------------------------

alter table knock.profiles add column if not exists kind text not null default 'person';
alter table knock.profiles drop constraint if exists profiles_kind_check;
alter table knock.profiles add constraint profiles_kind_check check (kind in ('person','business'));
alter table knock.profiles drop constraint if exists profiles_auth_fk;

-- People must still be Supabase auth users (when the auth schema exists).
create or replace function knock.check_profile_identity() returns trigger
language plpgsql as $$
begin
  if new.kind = 'person' and exists (select 1 from information_schema.tables where table_schema = 'auth' and table_name = 'users') then
    if not exists (select 1 from auth.users where id = new.id) then
      raise exception 'profile % has no auth user', new.id using errcode = '23503';
    end if;
  end if;
  if tg_op = 'UPDATE' and new.kind <> old.kind then
    raise exception 'a profile cannot change kind' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists profiles_identity on knock.profiles;
create trigger profiles_identity before insert or update on knock.profiles
  for each row execute function knock.check_profile_identity();

-- Staff are always people.
create or replace function knock.check_staff_is_person() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from knock.profiles where id = new.user_id and kind = 'person') then
    raise exception 'staff roles can only be granted to people' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists staff_roles_person on knock.staff_roles;
create trigger staff_roles_person before insert or update on knock.staff_roles
  for each row execute function knock.check_staff_is_person();

-- KYC officer joins the staff roles from the Business brief.
alter table knock.staff_roles drop constraint if exists staff_roles_role_check;
alter table knock.staff_roles add constraint staff_roles_role_check check (role in (
  'support','compliance','finance','admin',
  'super_admin','finance_manager','operations_manager','risk_officer','support_agent','analyst','technical',
  'kyc_officer'
));

alter table knock.audit_log add column if not exists business_id uuid;
create index if not exists audit_log_business on knock.audit_log (business_id, at desc) where business_id is not null;
create index if not exists audit_log_at on knock.audit_log (at desc);

-- ---------------------------------------------------------------------------
-- 1. Configuration (nothing about eligibility is hardcoded)
-- ---------------------------------------------------------------------------

-- Feature flags. Anything that needs a provider, a contract, a licence or a
-- credential stays disabled until Knock switches it on.
create table knock.feature_flags (
  key          text primary key,
  enabled      boolean not null default false,
  label        text not null,
  depends_on   text not null,             -- the exact dependency, shown in the UI
  updated_by   uuid references knock.profiles(id),
  updated_at   timestamptz not null default now()
);
insert into knock.feature_flags (key, enabled, label, depends_on) values
  ('business.accounts',        true,  'Knock Business accounts', 'Knock'),
  ('business.crypto_deposits', true,  'Crypto deposits (Breet)', 'Breet sandbox/production credentials; Breet written approval for pooled multi-customer funds'),
  ('business.crypto_payouts',  false, 'Crypto withdrawals (Breet)', 'Breet credentials + withdrawal PIN; Knock transaction-authorisation service; Breet approval'),
  ('business.bank_payouts',    false, 'Bank payouts NGN/GHS (Breet)', 'Breet credentials; saved bank account creation confirmed with Breet'),
  ('business.ngn_collections', false, 'Naira payment links', '9PSB collections API, contract and credentials (Breet is not a Naira gateway)'),
  ('business.crypto_links',    true,  'Crypto payment links', 'Breet deposit addresses per payment'),
  ('business.smart_split',     true,  'Smart Split', 'Underlying payment method being enabled'),
  ('business.auto_settlement', false, 'Automatic bank settlement', 'Breet per-address settlement; interaction with dashboard business-wide setting to confirm with Breet'),
  ('business.email',           false, 'Email notifications', 'Email service (not configured)');

create table knock.business_categories (
  code   text primary key,
  label  text not null,
  enabled boolean not null default true,
  high_risk boolean not null default false   -- routes verification to enhanced review
);
insert into knock.business_categories (code, label, high_risk) values
  ('online_retail','Online store / e-commerce', false),
  ('freelance','Freelancer / consultant', false),
  ('agency','Digital or creative agency', false),
  ('creator','Content creator', false),
  ('food','Food and restaurants', false),
  ('fashion','Fashion and beauty', false),
  ('education','Education and training', false),
  ('events','Events and ticketing', false),
  ('software','Software and SaaS', false),
  ('logistics','Logistics and delivery', false),
  ('ngo','Non-profit / organisation', true),
  ('other','Other', false);

-- What a business must provide before review, per country (and optionally
-- category). [Guess] Initial Nigerian list; compliance owns this table.
create table knock.business_verification_requirements (
  id          bigserial primary key,
  country     text not null,
  category    text references knock.business_categories(code),
  doc_type    text not null,
  label       text not null,
  required    boolean not null default true,
  min_representatives int not null default 0,
  unique (country, category, doc_type)
);
insert into knock.business_verification_requirements (country, category, doc_type, label, required, min_representatives) values
  ('NG', null, 'registration_certificate', 'CAC registration certificate (or business name certificate)', true, 1),
  ('NG', null, 'proof_of_address', 'Proof of business address (utility bill or lease, last 3 months)', true, 1),
  ('NG', null, 'representative_id', 'Government ID of each representative', true, 1),
  ('NG', null, 'tin', 'Tax Identification Number (TIN) document', false, 1),
  ('NG', 'ngo', 'board_resolution', 'Board resolution authorising the account', true, 2),
  ('GH', null, 'registration_certificate', 'Registrar-General certificate', true, 1),
  ('GH', null, 'representative_id', 'Government ID of each representative', true, 1);

-- Platform settings for business accounts. [Guess] values; Knock decides.
create table knock.business_settings (
  key   text primary key,
  value jsonb not null,
  note  text
);
insert into knock.business_settings values
  ('verified_tier', '2', 'KYC tier (limits) a verified business gets; see knock.tier_limits'),
  ('max_businesses_per_user', '5', 'How many businesses one person can own'),
  ('supported_countries', '["NG","GH"]', 'Countries a business can register in');

-- ---------------------------------------------------------------------------
-- 2. Businesses, members, roles, permissions
-- ---------------------------------------------------------------------------

create table knock.businesses (
  id                  uuid primary key references knock.profiles(id),  -- the business's account-holder profile
  owner_id            uuid not null references knock.profiles(id),
  legal_name          text not null check (length(legal_name) between 2 and 120),
  trading_name        text check (length(trading_name) <= 120),
  description         text check (length(description) <= 600),
  category            text not null references knock.business_categories(code),
  country             text not null check (country ~ '^[A-Z]{2}$'),
  email               text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 200),
  phone               text check (phone ~ '^\+?[0-9 ]{7,20}$'),
  website             text check (website ~* '^https://[^\s]+$' and length(website) <= 200),
  registration_number text check (length(registration_number) <= 40),
  logo_path           text,                    -- private storage path; public pages get a signed URL
  verification_status text not null default 'not_started' check (verification_status in
                        ('not_started','pending','under_review','info_required','verified','rejected','restricted')),
  verification_note   text,                    -- shown to the business (no internal notes)
  account_status      text not null default 'active' check (account_status in ('active','suspended','closed')),
  notification_prefs  jsonb not null default
    '{"payment_received":{"in_app":true,"email":true},"payout":{"in_app":true,"email":true},"split":{"in_app":true,"email":false},"verification":{"in_app":true,"email":true},"security":{"in_app":true,"email":true},"deposit":{"in_app":true,"email":false}}',
  payout_dual_approval_above numeric(38,0) not null default 0 check (payout_dual_approval_above >= 0), -- NGN kobo; 0 = every payout needs a second member
  submitted_at        timestamptz,
  verified_at         timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index businesses_owner on knock.businesses (owner_id);
create index businesses_status on knock.businesses (verification_status);

-- Role -> permission defaults. The owner can override per member.
create table knock.business_role_permissions (
  role       text not null check (role in ('owner','administrator','finance_manager','operations_manager','accountant','support','read_only')),
  permission text not null check (permission in (
               'dashboard.view','transactions.view','customers.view','links.create','links.manage','splits.manage',
               'crypto.receive','withdrawals.initiate','withdrawals.approve','reports.view','team.manage','settings.manage','verification.manage')),
  primary key (role, permission)
);
insert into knock.business_role_permissions (role, permission)
select 'owner', p from unnest(array['dashboard.view','transactions.view','customers.view','links.create','links.manage','splits.manage',
  'crypto.receive','withdrawals.initiate','withdrawals.approve','reports.view','team.manage','settings.manage','verification.manage']) p
union all select 'administrator', p from unnest(array['dashboard.view','transactions.view','customers.view','links.create','links.manage','splits.manage',
  'crypto.receive','withdrawals.initiate','reports.view','team.manage','settings.manage','verification.manage']) p
union all select 'finance_manager', p from unnest(array['dashboard.view','transactions.view','customers.view','crypto.receive','withdrawals.initiate','withdrawals.approve','reports.view']) p
union all select 'operations_manager', p from unnest(array['dashboard.view','transactions.view','customers.view','links.create','links.manage','splits.manage','crypto.receive']) p
union all select 'accountant', p from unnest(array['dashboard.view','transactions.view','customers.view','reports.view']) p
union all select 'support', p from unnest(array['dashboard.view','transactions.view','customers.view']) p
union all select 'read_only', p from unnest(array['dashboard.view','transactions.view']) p;

create table knock.business_members (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references knock.businesses(id),
  user_id     uuid not null references knock.profiles(id),
  role        text not null check (role in ('owner','administrator','finance_manager','operations_manager','accountant','support','read_only')),
  status      text not null default 'invited' check (status in ('invited','active','removed','declined')),
  invited_by  uuid references knock.profiles(id),
  created_at  timestamptz not null default now(),
  joined_at   timestamptz,
  removed_at  timestamptz,
  unique (business_id, user_id)
);
create unique index business_one_owner on knock.business_members (business_id) where role = 'owner' and status = 'active';
create index business_members_user on knock.business_members (user_id) where status in ('active','invited');

create table knock.business_member_permissions (
  business_id uuid not null references knock.businesses(id),
  user_id     uuid not null references knock.profiles(id),
  permission  text not null,
  allowed     boolean not null,
  set_by      uuid not null references knock.profiles(id),
  set_at      timestamptz not null default now(),
  primary key (business_id, user_id, permission)
);

-- ---------------------------------------------------------------------------
-- 3. Verification: documents, representatives, history
-- ---------------------------------------------------------------------------

-- Files live in a PRIVATE storage bucket. The API checks type and size,
-- stores the SHA-256 and never serves a public URL.
create table knock.business_documents (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references knock.businesses(id),
  doc_type     text not null,
  file_name    text not null check (length(file_name) <= 160),
  storage_path text not null,
  mime_type    text not null check (mime_type in ('application/pdf','image/jpeg','image/png')),
  size_bytes   int not null check (size_bytes between 1 and 10485760),
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  status       text not null default 'uploaded' check (status in ('uploaded','accepted','rejected','superseded')),
  review_note  text,
  uploaded_by  uuid not null references knock.profiles(id),
  reviewed_by  uuid references knock.profiles(id),
  created_at   timestamptz not null default now(),
  reviewed_at  timestamptz
);
create index business_documents_biz on knock.business_documents (business_id, doc_type);

create table knock.business_representatives (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references knock.businesses(id),
  full_name    text not null check (length(full_name) between 2 and 120),
  role_title   text not null check (length(role_title) between 2 and 60),
  ownership_bps int check (ownership_bps between 0 and 10000),
  email        text check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  user_id      uuid references knock.profiles(id),      -- when the representative is a Knock user
  kyc_status   text not null default 'pending' check (kyc_status in ('pending','verified','rejected')),
  status       text not null default 'active' check (status in ('active','removed')),
  created_at   timestamptz not null default now()
);

create table knock.business_verification_events (
  id          bigserial primary key,
  business_id uuid not null references knock.businesses(id),
  from_status text,
  to_status   text not null,
  actor_id    uuid,
  actor_kind  text not null check (actor_kind in ('user','staff','system')),
  note        text,
  at          timestamptz not null default now()
);
create trigger business_verification_events_immutable before update or delete on knock.business_verification_events
  for each row execute function knock.forbid_change();

-- Keep the business profile's status and tier in step with verification and
-- account status. Engines read these, so this is the enforcement point.
create or replace function knock.sync_business_profile() returns trigger
language plpgsql as $$
declare v_tier int := (select (value #>> '{}')::int from knock.business_settings where key = 'verified_tier');
begin
  update knock.profiles set
    kyc_tier = case when new.verification_status = 'verified' then coalesce(v_tier, 1) else 0 end,
    status = case when new.account_status = 'closed' then 'closed'
                  when new.account_status = 'suspended' or new.verification_status = 'restricted' then 'frozen'
                  else 'active' end,
    display_name = coalesce(nullif(new.trading_name, ''), new.legal_name)
  where id = new.id;
  if tg_op = 'UPDATE' and new.verification_status is distinct from old.verification_status then
    new.updated_at := now();
  end if;
  return new;
end $$;
create trigger businesses_sync_profile after insert or update of verification_status, account_status, trading_name, legal_name
  on knock.businesses for each row execute function knock.sync_business_profile();

-- ---------------------------------------------------------------------------
-- 4. Permission checks (server-side; the UI only mirrors them)
-- ---------------------------------------------------------------------------

create or replace function knock.business_permissions(p_user uuid, p_business uuid) returns text[]
language sql stable as $$
  with m as (
    select bm.role from knock.business_members bm
    join knock.profiles pu on pu.id = bm.user_id and pu.status = 'active' and pu.kind = 'person'
    where bm.business_id = p_business and bm.user_id = p_user and bm.status = 'active'
  ), base as (
    select rp.permission from knock.business_role_permissions rp join m on m.role = rp.role
  ), ov as (
    select permission, allowed from knock.business_member_permissions where business_id = p_business and user_id = p_user
  )
  select coalesce(array_agg(distinct p order by p), '{}') from (
    select permission p from base where permission not in (select permission from ov where not allowed)
    union
    -- owner-granted extras (only the owner can set overrides)
    select permission from ov where allowed and exists (select 1 from m)
  ) x
$$;

create or replace function knock.business_can(p_user uuid, p_business uuid, p_perm text) returns boolean
language sql stable as $$ select p_perm = any(knock.business_permissions(p_user, p_business)) $$;

create or replace function knock.require_business(p_user uuid, p_business uuid, p_perm text) returns knock.businesses
language plpgsql as $$
declare b knock.businesses;
begin
  select * into b from knock.businesses where id = p_business;
  if not found then perform knock.fail('not_found', 'business not found'); end if;
  if not knock.business_can(p_user, p_business, p_perm) then
    perform knock.fail('forbidden', 'you do not have permission to do this for this business');
  end if;
  if b.account_status = 'closed' then perform knock.fail('account_restricted', 'this business account is closed'); end if;
  return b;
end $$;

-- Money actions additionally need a verified, unrestricted business and an
-- enabled feature flag.
create or replace function knock.require_business_money(p_user uuid, p_business uuid, p_perm text, p_flag text) returns knock.businesses
language plpgsql as $$
declare b knock.businesses;
begin
  b := knock.require_business(p_user, p_business, p_perm);
  if b.verification_status <> 'verified' then
    perform knock.fail('verification_required', 'complete business verification first');
  end if;
  if b.account_status <> 'active' then perform knock.fail('account_restricted', 'this business account is restricted'); end if;
  if p_flag is not null and not coalesce((select enabled from knock.feature_flags where key = p_flag), false) then
    perform knock.fail('feature_disabled', coalesce((select label || ' is not enabled yet. Needs: ' || depends_on from knock.feature_flags where key = p_flag), 'not enabled'));
  end if;
  return b;
end $$;

create or replace function knock.baudit(p_actor uuid, p_business uuid, p_action text, p_detail jsonb) returns void
language sql as $$
  insert into knock.audit_log (actor_id, actor_kind, action, business_id, detail)
  values (p_actor, 'user', p_action, p_business, p_detail)
$$;

-- ---------------------------------------------------------------------------
-- 5. Onboarding
-- ---------------------------------------------------------------------------

-- p: {handle, legal_name, trading_name, description, category, country, email, phone, website, registration_number}
create or replace function knock.create_business(p_user uuid, p jsonb) returns jsonb
language plpgsql as $$
declare u knock.profiles; v_id uuid := gen_random_uuid(); v_max int; v_handle text := lower(ltrim(coalesce(p->>'handle',''), '@'));
begin
  select * into u from knock.profiles where id = p_user for update;
  if not found or u.kind <> 'person' then perform knock.fail('forbidden', 'sign in with a personal Knock account'); end if;
  if u.status <> 'active' then perform knock.fail('account_restricted', 'your account is restricted'); end if;
  if not coalesce((select enabled from knock.feature_flags where key = 'business.accounts'), false) then
    perform knock.fail('feature_disabled', 'Knock Business is not open yet');
  end if;
  v_max := (select (value #>> '{}')::int from knock.business_settings where key = 'max_businesses_per_user');
  if (select count(*) from knock.businesses where owner_id = p_user and account_status <> 'closed') >= coalesce(v_max, 5) then
    perform knock.fail('limit_exceeded', 'you have reached the number of businesses you can own');
  end if;
  if v_handle !~ '^[a-z0-9_]{3,20}$' then perform knock.fail('invalid_handle', 'handle must be 3-20 letters, numbers or _'); end if;
  if exists (select 1 from knock.profiles where lower(username) = v_handle) then perform knock.fail('handle_taken', 'that handle is taken'); end if;
  if not exists (select 1 from knock.business_categories where code = p->>'category' and enabled) then
    perform knock.fail('bad_request', 'choose a business category');
  end if;
  if not ((select value from knock.business_settings where key = 'supported_countries') ? upper(coalesce(p->>'country',''))) then
    perform knock.fail('unsupported_country', 'Knock Business is not available in that country yet');
  end if;

  insert into knock.profiles (id, username, display_name, kind, kyc_tier, status)
  values (v_id, v_handle, coalesce(nullif(p->>'trading_name',''), p->>'legal_name', v_handle), 'business', 0, 'active');
  insert into knock.businesses (id, owner_id, legal_name, trading_name, description, category, country, email, phone, website, registration_number)
  values (v_id, p_user, p->>'legal_name', nullif(p->>'trading_name',''), nullif(p->>'description',''), p->>'category', upper(p->>'country'),
          lower(p->>'email'), nullif(p->>'phone',''), nullif(p->>'website',''), nullif(p->>'registration_number',''));
  insert into knock.business_members (business_id, user_id, role, status, joined_at) values (v_id, p_user, 'owner', 'active', now());
  insert into knock.business_verification_events (business_id, from_status, to_status, actor_id, actor_kind) values (v_id, null, 'not_started', p_user, 'user');
  perform knock.baudit(p_user, v_id, 'business.created', jsonb_build_object('handle', v_handle, 'category', p->>'category', 'country', upper(p->>'country')));
  return jsonb_build_object('id', v_id, 'handle', v_handle);
end $$;

create or replace function knock.update_business_profile(p_user uuid, p_business uuid, p jsonb) returns void
language plpgsql as $$
declare b knock.businesses; v_locked boolean;
begin
  b := knock.require_business(p_user, p_business, 'settings.manage');
  -- Legal identity is fixed once submitted; changing it restarts verification.
  v_locked := b.verification_status in ('pending','under_review','verified');
  if v_locked and (p ? 'legal_name' or p ? 'registration_number' or p ? 'country') then
    perform knock.fail('locked', 'legal name, registration number and country cannot change after submission; contact support');
  end if;
  update knock.businesses set
    legal_name = coalesce(p->>'legal_name', legal_name),
    trading_name = case when p ? 'trading_name' then nullif(p->>'trading_name','') else trading_name end,
    description = case when p ? 'description' then nullif(p->>'description','') else description end,
    category = coalesce(p->>'category', category),
    country = coalesce(upper(p->>'country'), country),
    email = coalesce(lower(p->>'email'), email),
    phone = case when p ? 'phone' then nullif(p->>'phone','') else phone end,
    website = case when p ? 'website' then nullif(p->>'website','') else website end,
    registration_number = case when p ? 'registration_number' then nullif(p->>'registration_number','') else registration_number end,
    logo_path = case when p ? 'logo_path' then nullif(p->>'logo_path','') else logo_path end,
    notification_prefs = case when p ? 'notification_prefs' then p->'notification_prefs' else notification_prefs end,
    payout_dual_approval_above = coalesce((p->>'payout_dual_approval_above')::numeric, payout_dual_approval_above),
    updated_at = now()
  where id = p_business;
  -- Sensitive changes are flagged for risk review (suspicious account changes).
  if p ? 'email' and lower(p->>'email') <> b.email and b.verification_status = 'verified' then
    insert into knock.risk_flags (user_id, rule, severity, detail, subject_kind, subject_id)
    values (p_business, 'business_contact_changed', 'low', jsonb_build_object('field', 'email', 'by', p_user), 'business', p_business);
  end if;
  perform knock.baudit(p_user, p_business, 'business.updated', p - 'notification_prefs');
end $$;

-- p: {doc_type, file_name, storage_path, mime_type, size_bytes, sha256}
create or replace function knock.add_business_document(p_user uuid, p_business uuid, p jsonb) returns uuid
language plpgsql as $$
declare b knock.businesses; v_id uuid;
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status in ('under_review','verified','restricted') then
    perform knock.fail('locked', 'documents cannot be changed while under review or after verification');
  end if;
  update knock.business_documents set status = 'superseded'
  where business_id = p_business and doc_type = p->>'doc_type' and status = 'uploaded';
  insert into knock.business_documents (business_id, doc_type, file_name, storage_path, mime_type, size_bytes, sha256, uploaded_by)
  values (p_business, p->>'doc_type', p->>'file_name', p->>'storage_path', p->>'mime_type', (p->>'size_bytes')::int, lower(p->>'sha256'), p_user)
  returning id into v_id;
  perform knock.baudit(p_user, p_business, 'business.document.added', jsonb_build_object('doc_type', p->>'doc_type', 'sha256', p->>'sha256'));
  return v_id;
end $$;

create or replace function knock.add_business_representative(p_user uuid, p_business uuid, p jsonb) returns uuid
language plpgsql as $$
declare b knock.businesses; v_id uuid; v_rep uuid;
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status in ('under_review','verified') then perform knock.fail('locked', 'contact support to change representatives'); end if;
  if p->>'username' is not null then
    select id into v_rep from knock.lookup_username(p->>'username');
    if v_rep is null then perform knock.fail('not_found', 'no Knock user with that username'); end if;
  end if;
  insert into knock.business_representatives (business_id, full_name, role_title, ownership_bps, email, user_id)
  values (p_business, p->>'full_name', p->>'role_title', (p->>'ownership_bps')::int, nullif(p->>'email',''), v_rep)
  returning id into v_id;
  perform knock.baudit(p_user, p_business, 'business.representative.added', jsonb_build_object('representative_id', v_id));
  return v_id;
end $$;

-- What is still missing before the business can submit.
create or replace function knock.business_verification_checklist(p_business uuid) returns jsonb
language sql stable as $$
  with b as (select * from knock.businesses where id = p_business),
  req as (
    select r.* from knock.business_verification_requirements r, b
    where r.country = b.country and (r.category is null or r.category = b.category)
  ),
  docs as (
    select req.doc_type, req.label, req.required,
           exists (select 1 from knock.business_documents d where d.business_id = p_business and d.doc_type = req.doc_type
                   and d.status in ('uploaded','accepted')) as provided,
           (select d.status from knock.business_documents d where d.business_id = p_business and d.doc_type = req.doc_type
            and d.status <> 'superseded' order by d.created_at desc limit 1) as doc_status
    from req
  )
  select jsonb_build_object(
    'documents', coalesce((select jsonb_agg(to_jsonb(docs) order by required desc, label) from docs), '[]'),
    'representatives_required', coalesce((select max(min_representatives) from req), 0),
    'representatives', (select count(*) from knock.business_representatives where business_id = p_business and status = 'active'),
    'profile_complete', (select b.legal_name is not null and b.email is not null and b.category is not null from b),
    'ready', (select bool_and(provided) from docs where required) is not false
             and (select count(*) from knock.business_representatives where business_id = p_business and status = 'active')
                 >= coalesce((select max(min_representatives) from req), 0)
  )
$$;

create or replace function knock.set_business_verification(p_business uuid, p_to text, p_actor uuid, p_actor_kind text, p_note text)
returns void language plpgsql as $$
declare b knock.businesses;
begin
  select * into b from knock.businesses where id = p_business for update;
  update knock.businesses set verification_status = p_to,
    verification_note = case when p_actor_kind = 'staff' then p_note else verification_note end,
    submitted_at = case when p_to = 'pending' then now() else submitted_at end,
    verified_at = case when p_to = 'verified' then now() else verified_at end,
    updated_at = now()
  where id = p_business;
  insert into knock.business_verification_events (business_id, from_status, to_status, actor_id, actor_kind, note)
  values (p_business, b.verification_status, p_to, p_actor, p_actor_kind, p_note);
  perform knock.notify(p_business, 'verification', 'Verification update',
    case p_to when 'pending' then 'We received your verification. We''ll review it shortly.'
              when 'under_review' then 'Your business is being reviewed.'
              when 'info_required' then 'We need a little more information: ' || coalesce(p_note, 'see Settings > Verification.')
              when 'verified' then 'Your business is verified. You can now collect and move money.'
              when 'rejected' then 'We could not verify your business. ' || coalesce(p_note, '')
              when 'restricted' then 'Some features on your business account are restricted. Contact support.'
              else 'Your verification status changed.' end, null, null, jsonb_build_object('status', p_to));
end $$;

create or replace function knock.submit_business_verification(p_user uuid, p_business uuid) returns text
language plpgsql as $$
declare b knock.businesses; c jsonb;
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status not in ('not_started','info_required','rejected') then
    perform knock.fail('bad_state', 'verification is already ' || b.verification_status);
  end if;
  c := knock.business_verification_checklist(p_business);
  if not (c->>'ready')::boolean then perform knock.fail('incomplete', 'add the required documents and representatives first'); end if;
  perform knock.set_business_verification(p_business, 'pending', p_user, 'user', null);
  perform knock.baudit(p_user, p_business, 'business.verification.submitted', c);
  return 'pending';
end $$;

-- ---------------------------------------------------------------------------
-- 6. Team
-- ---------------------------------------------------------------------------

create or replace function knock.invite_business_member(p_user uuid, p_business uuid, p_username text, p_role text) returns uuid
language plpgsql as $$
declare v_target uuid; v_id uuid; v_kind text;
begin
  perform knock.require_business(p_user, p_business, 'team.manage');
  if p_role = 'owner' then perform knock.fail('bad_request', 'transfer ownership instead'); end if;
  if p_role = 'administrator' and not knock.business_can(p_user, p_business, 'withdrawals.approve') then
    perform knock.fail('forbidden', 'only the owner can add administrators');
  end if;
  select id, kind into v_target, v_kind from knock.profiles where lower(username) = lower(ltrim(p_username,'@')) and status = 'active';
  if v_target is null or v_kind <> 'person' then perform knock.fail('not_found', 'no Knock user with that username'); end if;
  insert into knock.business_members (business_id, user_id, role, status, invited_by)
  values (p_business, v_target, p_role, 'invited', p_user)
  on conflict (business_id, user_id) do update set role = excluded.role, status = 'invited', invited_by = p_user, removed_at = null
    where knock.business_members.status in ('removed','declined')
  returning id into v_id;
  if v_id is null then perform knock.fail('already_member', '@' || ltrim(p_username,'@') || ' is already on the team'); end if;
  perform knock.notify(v_target, 'business_invite', 'Team invitation',
    format('You were invited to join %s on Knock Business.', (select display_name from knock.profiles where id = p_business)), null, null,
    jsonb_build_object('business_id', p_business, 'role', p_role));
  perform knock.baudit(p_user, p_business, 'business.member.invited', jsonb_build_object('user_id', v_target, 'role', p_role));
  return v_id;
end $$;

create or replace function knock.respond_business_invite(p_user uuid, p_business uuid, p_accept boolean) returns text
language plpgsql as $$
declare m record;
begin
  select * into m from knock.business_members where business_id = p_business and user_id = p_user and status = 'invited' for update;
  if not found then perform knock.fail('not_found', 'no pending invitation'); end if;
  update knock.business_members set status = case when p_accept then 'active' else 'declined' end,
    joined_at = case when p_accept then now() end where id = m.id;
  perform knock.baudit(p_user, p_business, case when p_accept then 'business.member.joined' else 'business.member.declined' end, '{}');
  return case when p_accept then 'active' else 'declined' end;
end $$;

-- p: {role?, remove?, permissions?: {perm: true|false|null}}
create or replace function knock.update_business_member(p_user uuid, p_business uuid, p_member_user uuid, p jsonb) returns void
language plpgsql as $$
declare m record; k text; v jsonb;
begin
  perform knock.require_business(p_user, p_business, 'team.manage');
  select * into m from knock.business_members where business_id = p_business and user_id = p_member_user for update;
  if not found then perform knock.fail('not_found', 'member not found'); end if;
  if m.role = 'owner' then perform knock.fail('forbidden', 'the owner cannot be changed here'); end if;
  if p_member_user = p_user then perform knock.fail('forbidden', 'you cannot change your own access'); end if;
  if (m.role = 'administrator' or p->>'role' = 'administrator' or p ? 'permissions')
     and not exists (select 1 from knock.business_members where business_id = p_business and user_id = p_user and role = 'owner' and status = 'active') then
    perform knock.fail('forbidden', 'only the owner can change administrators or individual permissions');
  end if;
  if coalesce((p->>'remove')::boolean, false) then
    update knock.business_members set status = 'removed', removed_at = now() where id = m.id;
    delete from knock.business_member_permissions where business_id = p_business and user_id = p_member_user;
  elsif p ? 'role' then
    if p->>'role' = 'owner' then perform knock.fail('bad_request', 'ownership transfer is a separate, verified process'); end if;
    update knock.business_members set role = p->>'role' where id = m.id;
  end if;
  if p ? 'permissions' then
    for k, v in select * from jsonb_each(p->'permissions') loop
      if not exists (select 1 from knock.business_role_permissions where permission = k) then
        perform knock.fail('bad_request', 'unknown permission ' || k);
      end if;
      if v = 'null'::jsonb then
        delete from knock.business_member_permissions where business_id = p_business and user_id = p_member_user and permission = k;
      else
        insert into knock.business_member_permissions (business_id, user_id, permission, allowed, set_by)
        values (p_business, p_member_user, k, (v #>> '{}')::boolean, p_user)
        on conflict (business_id, user_id, permission) do update set allowed = excluded.allowed, set_by = p_user, set_at = now();
      end if;
    end loop;
  end if;
  perform knock.baudit(p_user, p_business, 'business.member.updated', jsonb_build_object('user_id', p_member_user) || p);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Business money actions (thin, permission-checked wrappers over the
--    existing engines: no money logic is duplicated here)
-- ---------------------------------------------------------------------------

alter table knock.payment_links add column if not exists created_by_member uuid references knock.profiles(id);

create or replace function knock.business_create_link(p_user uuid, p_business uuid, p jsonb) returns jsonb
language plpgsql as $$
declare v jsonb; v_flag text;
begin
  v_flag := case when p->>'link_type' = 'split' then 'business.smart_split'
                 when p->>'currency' = 'NGN' then 'business.ngn_collections' else 'business.crypto_links' end;
  perform knock.require_business_money(p_user, p_business, case when p->>'link_type' = 'split' then 'splits.manage' else 'links.create' end, v_flag);
  if p->>'link_type' = 'split' and p->>'currency' = 'NGN' then
    perform knock.require_business_money(p_user, p_business, 'splits.manage', 'business.ngn_collections');
  end if;
  v := knock.create_payment_link(p_business, p);
  update knock.payment_links set created_by_member = p_user where id = (v->>'id')::uuid;
  perform knock.baudit(p_user, p_business, 'business.link.created', v);
  return v;
end $$;

create or replace function knock.business_link_action(p_user uuid, p_business uuid, p_link uuid, p_action text) returns text
language plpgsql as $$
declare v text;
begin
  perform knock.require_business(p_user, p_business, 'links.manage');
  if not exists (select 1 from knock.payment_links where id = p_link and creator_id = p_business) then
    perform knock.fail('not_found', 'link not found');
  end if;
  if p_action not in ('pause','resume','close') then perform knock.fail('bad_request', 'unknown action'); end if;
  v := knock.set_link_status(p_link, p_business, p_action, null);
  perform knock.baudit(p_user, p_business, 'business.link.' || p_action, jsonb_build_object('link_id', p_link));
  return v;
end $$;

create or replace function knock.business_request_address(p_user uuid, p_business uuid, p_provider text, p_asset_id text, p_symbol text, p_network text)
returns jsonb language plpgsql as $$
begin
  perform knock.require_business_money(p_user, p_business, 'crypto.receive', 'business.crypto_deposits');
  perform knock.baudit(p_user, p_business, 'business.address.requested', jsonb_build_object('asset_id', p_asset_id));
  return knock.request_deposit_address(p_business, p_provider, p_asset_id, p_symbol, p_network, null, false);
end $$;

-- Payouts: maker-checker inside the business. A request records intent and
-- the destination; funds are reserved in the ledger by the existing
-- knock.reserve_withdrawal only once approved (by a different member when
-- above the business's threshold). Submission to Breet is the existing
-- CryptoService path, which also needs transaction authorisation.
create table knock.business_payout_requests (
  id            uuid primary key default gen_random_uuid(),
  reference     text not null unique default knock.new_ref('KBP'),
  business_id   uuid not null references knock.businesses(id),
  kind          text not null check (kind in ('crypto','bank')),
  currency      text not null,
  amount_minor  numeric(38,0) not null check (amount_minor > 0),
  payload       jsonb not null,           -- destination etc. as passed to reserve_withdrawal
  status        text not null default 'pending_approval' check (status in ('pending_approval','approved','rejected','cancelled','failed')),
  requested_by  uuid not null references knock.profiles(id),
  approved_by   uuid references knock.profiles(id),
  needs_second_approver boolean not null,
  withdrawal_id uuid references knock.provider_withdrawals(id),
  note          text,
  error         text,
  created_at    timestamptz not null default now(),
  decided_at    timestamptz,
  check (approved_by is null or not needs_second_approver or approved_by <> requested_by)
);
create index business_payout_requests_biz on knock.business_payout_requests (business_id, created_at desc);

create or replace function knock.business_request_payout(p_user uuid, p_business uuid, p jsonb) returns jsonb
language plpgsql as $$
declare b knock.businesses; v_amt numeric := (p->>'amount_minor')::numeric; v_cur text := upper(p->>'currency');
        v_avail numeric; v_id uuid; v_dual boolean; v_ref text;
begin
  b := knock.require_business_money(p_user, p_business, 'withdrawals.initiate',
         case when p->>'kind' = 'bank' then 'business.bank_payouts' else 'business.crypto_payouts' end);
  if v_amt is null or v_amt <= 0 then perform knock.fail('bad_request', 'amount must be positive'); end if;
  v_avail := coalesce(knock.balance(knock.account(p_business, null, 'user_available', v_cur)), 0);
  if v_avail < v_amt then perform knock.fail('insufficient_funds', 'the business balance is too low for this payout'); end if;
  v_dual := not (v_cur = 'NGN' and v_amt <= b.payout_dual_approval_above);
  insert into knock.business_payout_requests (business_id, kind, currency, amount_minor, payload, requested_by, needs_second_approver, note)
  values (p_business, p->>'kind', v_cur, v_amt, p - 'note', p_user, v_dual, left(p->>'note', 140))
  returning id, reference into v_id, v_ref;
  perform knock.baudit(p_user, p_business, 'business.payout.requested', jsonb_build_object('request_id', v_id, 'amount_minor', v_amt::text, 'currency', v_cur));
  if v_dual then
    perform knock.notify(p_business, 'payout', 'Payout waiting for approval',
      format('%s requested a payout (%s). A second approver must confirm it.', (select '@' || username from knock.profiles where id = p_user), v_ref),
      null, null, jsonb_build_object('request_id', v_id));
    return jsonb_build_object('id', v_id, 'reference', v_ref, 'status', 'pending_approval', 'needs_second_approver', true);
  end if;
  return knock.business_decide_payout(p_user, p_business, v_id, true, null);
end $$;

create or replace function knock.business_decide_payout(p_user uuid, p_business uuid, p_request uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql as $$
declare r record; v jsonb;
begin
  perform knock.require_business_money(p_user, p_business, 'withdrawals.approve', null);
  select * into r from knock.business_payout_requests where id = p_request and business_id = p_business for update;
  if not found then perform knock.fail('not_found', 'payout request not found'); end if;
  if r.status <> 'pending_approval' then perform knock.fail('bad_state', 'this payout is already ' || r.status); end if;
  if p_approve and r.needs_second_approver and r.requested_by = p_user then
    perform knock.fail('second_approver_required', 'a different team member must approve this payout');
  end if;
  if not p_approve then
    update knock.business_payout_requests set status = 'rejected', approved_by = p_user, decided_at = now(), note = coalesce(p_note, note) where id = r.id;
    perform knock.baudit(p_user, p_business, 'business.payout.rejected', jsonb_build_object('request_id', r.id));
    return jsonb_build_object('id', r.id, 'status', 'rejected');
  end if;
  v := knock.reserve_withdrawal(p_business, coalesce(r.payload->>'provider', 'breet'),
         r.payload || jsonb_build_object('idempotency_key', 'business-payout:' || r.id));
  update knock.provider_withdrawals set created_by = r.requested_by, approved_by = p_user where id = (v#>>'{withdrawal,id}')::uuid;
  update knock.business_payout_requests set status = 'approved', approved_by = p_user, decided_at = now(),
    withdrawal_id = (v#>>'{withdrawal,id}')::uuid where id = r.id;
  perform knock.baudit(p_user, p_business, 'business.payout.approved', jsonb_build_object('request_id', r.id, 'withdrawal_id', v#>>'{withdrawal,id}'));
  return jsonb_build_object('id', r.id, 'status', 'approved', 'withdrawal_id', v#>>'{withdrawal,id}');
end $$;

-- ---------------------------------------------------------------------------
-- 8. One view of every transaction, for any account holder
-- ---------------------------------------------------------------------------
-- state: succeeded | pending | failed | reversed. Amounts are minor units of
-- `currency`. direction is from the holder's point of view.

create or replace view knock.holder_transactions as
-- Collections through the holder's payment links
select p.id, l.creator_id as holder_id, 'payment_link_collection'::text as category, 'in'::text as direction,
       p.knock_reference as reference, p.created_at as occurred_at,
       coalesce(nullif(p.payer_name,''), p.payer_email, 'Customer') as counterparty,
       p.currency, p.amount, p.knock_fee as fees,
       p.amount - case when l.fee_bearer = 'deduct' then p.knock_fee else 0 end as net,
       p.provider, p.provider_reference, p.status as provider_status,
       case when p.status = 'succeeded' then 'succeeded' when p.status in ('failed','expired') then 'failed'
            when p.status in ('reversed') then 'reversed' when p.status = 'disputed' then 'pending' else 'pending' end as state,
       l.id as link_id, l.title as link_title, p.method, p.payer_email
from knock.payments p join knock.payment_links l on l.id = p.link_id
union all
-- Shares received from Smart Split links (including the creator's own share)
select a.id, a.recipient_id, 'split_distribution', 'in', l.reference, a.created_at,
       (select display_name from knock.profiles where id = l.creator_id), a.currency, a.gross_share, a.fee_share, a.net_share,
       p.provider, p.knock_reference, s.state,
       case when s.state in ('available') then 'succeeded' when s.state = 'reversed' then 'reversed' else 'pending' end,
       l.id, l.title, p.method, null
from knock.split_allocations a join knock.allocation_state s on s.id = a.id
join knock.payment_links l on l.id = a.link_id join knock.payments p on p.id = a.payment_id
where l.link_type = 'split'
union all
select d.id, d.user_id, 'crypto_deposit', 'in', d.knock_reference, d.created_at,
       coalesce(d.symbol, 'Crypto') || coalesce(' · ' || nullif(d.network,''), ''),
       coalesce(d.credited_currency, 'USD'), coalesce(d.credited_minor, 0), d.knock_fee_minor, coalesce(d.customer_net_minor, 0),
       d.provider, d.provider_trade_id, d.status,
       case when d.status = 'completed' then 'succeeded' when d.status = 'failed' then 'failed' else 'pending' end,
       null, null, 'crypto', null
from knock.crypto_deposits d
union all
select w.id, w.user_id, case when w.kind = 'crypto' then 'crypto_withdrawal' else 'bank_payout' end, 'out', w.knock_reference, w.created_at,
       case when w.kind = 'crypto' then coalesce(w.asset,'') || ' to ' || left(coalesce(w.destination_address,''), 6) || '…' || right(coalesce(w.destination_address,''), 4)
            else coalesce(w.bank_name,'') || ' ' || coalesce(w.account_number_masked,'') end,
       w.currency, w.amount_minor, w.knock_fee_minor, w.amount_minor, w.provider, w.provider_withdrawal_id, w.status,
       case when w.status = 'completed' then 'succeeded' when w.status in ('rejected','not_submitted','capacity_unavailable') then 'failed'
            when w.status = 'reversed' then 'reversed' else 'pending' end,
       null, null, w.kind, null
from knock.provider_withdrawals w;

-- Open risk flags per holder, for the risk_status column.
create or replace function knock.holder_risk_status(p_holder uuid) returns text
language sql stable as $$
  select coalesce((select max(severity) from knock.risk_flags where user_id = p_holder and status = 'open'), 'clear')
$$;

-- ---------------------------------------------------------------------------
-- 9. Business overview: every figure from ledger and transaction records
-- ---------------------------------------------------------------------------

create or replace function knock.business_overview(p_user uuid, p_business uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable as $$
declare b knock.businesses; v jsonb;
begin
  b := knock.require_business(p_user, p_business, 'dashboard.view');
  with t as (select * from knock.holder_transactions where holder_id = p_business and occurred_at >= p_from and occurred_at < p_to),
  bal as (
    select currency,
      sum(balance) filter (where purpose = 'user_available') as available,
      sum(balance) filter (where purpose = 'user_pending') as pending,
      sum(balance) filter (where purpose in ('user_withdrawal_reserved','user_settlement_reserved')) as reserved,
      sum(balance) filter (where purpose = 'user_held') as held
    from knock.account_balances where owner_id = p_business group by currency
  ),
  by_cur as (
    select currency,
      sum(amount) filter (where direction = 'in' and state = 'succeeded' and category <> 'split_distribution') as collected,
      sum(amount) filter (where direction = 'out' and state = 'succeeded') as paid_out,
      sum(fees) filter (where state = 'succeeded' and category <> 'split_distribution') as fees,
      count(*) filter (where direction = 'in' and category <> 'split_distribution') as payments,
      count(*) filter (where direction = 'in' and category <> 'split_distribution' and state = 'succeeded') as payments_ok,
      avg(amount) filter (where direction = 'in' and state = 'succeeded' and category <> 'split_distribution') as avg_value
    from t group by currency
  ),
  series as (
    select date_trunc('day', occurred_at) as day, currency, sum(amount) as amount, count(*) as n
    from t where direction = 'in' and state = 'succeeded' and category <> 'split_distribution' group by 1, 2
  ),
  links as (
    select l.id, l.title, l.reference, l.status, l.link_type, l.currency,
           count(p.id) filter (where p.status = 'succeeded') as payments,
           coalesce(sum(p.amount) filter (where p.status = 'succeeded'), 0) as collected
    from knock.payment_links l left join knock.payments p on p.link_id = l.id and p.created_at >= p_from and p.created_at < p_to
    where l.creator_id = p_business group by l.id order by collected desc, l.created_at desc limit 5
  )
  select jsonb_build_object(
    'business', jsonb_build_object('id', b.id, 'name', coalesce(b.trading_name, b.legal_name), 'verification_status', b.verification_status, 'account_status', b.account_status),
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'balances', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'available', coalesce(available,0)::text, 'pending', coalesce(pending,0)::text,
                     'reserved', coalesce(reserved,0)::text, 'held', coalesce(held,0)::text)) from bal), '[]'),
    'totals', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'collected', coalesce(collected,0)::text, 'paid_out', coalesce(paid_out,0)::text,
                     'fees', coalesce(fees,0)::text, 'payments', payments, 'successful', payments_ok,
                     'average', coalesce(round(avg_value),0)::text,
                     'success_rate', case when payments > 0 then round(100.0 * payments_ok / payments, 1) end)) from by_cur), '[]'),
    'counts', jsonb_build_object(
       'succeeded', (select count(*) from t where state = 'succeeded'),
       'pending', (select count(*) from t where state = 'pending'),
       'failed', (select count(*) from t where state = 'failed'),
       'reversed', (select count(*) from t where state = 'reversed'),
       'customers', (select count(distinct lower(payer_email)) from t where payer_email is not null and state = 'succeeded')),
    'settlements', jsonb_build_object(
       'awaiting', (select count(*) from knock.settlements where user_id = p_business and status in ('awaiting_payout','processing')),
       'failed', (select count(*) from knock.settlements where user_id = p_business and status in ('failed_to_start','needs_review')),
       'completed', (select count(*) from knock.settlements where user_id = p_business and status = 'completed')),
    'series', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'currency', currency, 'amount', amount::text, 'count', n) order by day) from series), '[]'),
    'top_links', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'title', title, 'reference', reference, 'status', status, 'type', link_type,
                     'currency', currency, 'payments', payments, 'collected', collected::text)) from links), '[]'),
    'recent', coalesce((select jsonb_agg(x) from (select id, category, direction, reference, occurred_at, counterparty, currency, amount::text as amount,
                     state, provider_status from knock.holder_transactions where holder_id = p_business order by occurred_at desc limit 8) x), '[]'),
    'pending_payouts', (select count(*) from knock.business_payout_requests where business_id = p_business and status = 'pending_approval'),
    'risk_alerts', (select count(*) from knock.risk_flags where user_id = p_business and status = 'open'),
    'risk_status', knock.holder_risk_status(p_business)
  ) into v;
  return v;
end $$;

-- Business customers, from successful payments on its links.
create or replace view knock.business_customers as
select l.creator_id as business_id, lower(p.payer_email) as email, max(p.payer_name) as name, p.currency,
       count(*) as payments, sum(p.amount) as total, min(p.created_at) as first_paid_at, max(p.created_at) as last_paid_at
from knock.payments p join knock.payment_links l on l.id = p.link_id
where p.status = 'succeeded' and p.payer_email is not null
group by 1, 2, 4;

-- ---------------------------------------------------------------------------
-- 10. Knock admin: permissions, MFA marker, dual approval
-- ---------------------------------------------------------------------------

create table knock.admin_role_permissions (
  role       text not null,
  permission text not null,
  primary key (role, permission)
);
insert into knock.admin_role_permissions (role, permission)
select 'super_admin', p from unnest(array['overview.view','transactions.view','users.view','users.restrict','businesses.view','businesses.verify',
  'businesses.restrict','links.view','links.review','risk.view','risk.manage','lists.manage','lists.approve','kyc.view','kyc.review',
  'earnings.view','support.view','support.manage','reports.view','providers.view','reconciliation.manage','settlements.manage',
  'staff.manage','audit.view','settings.manage','notifications.view']) p
union all select 'finance_manager', p from unnest(array['overview.view','transactions.view','users.view','businesses.view','links.view',
  'earnings.view','reports.view','providers.view','reconciliation.manage','settlements.manage','audit.view','notifications.view','risk.view']) p
union all select 'operations_manager', p from unnest(array['overview.view','transactions.view','users.view','businesses.view','links.view','links.review',
  'support.view','support.manage','reports.view','providers.view','notifications.view','risk.view','kyc.view']) p
union all select 'risk_officer', p from unnest(array['overview.view','transactions.view','users.view','users.restrict','businesses.view','businesses.restrict',
  'links.view','links.review','risk.view','risk.manage','lists.manage','lists.approve','kyc.view','audit.view','notifications.view']) p
union all select 'kyc_officer', p from unnest(array['overview.view','users.view','businesses.view','businesses.verify','kyc.view','kyc.review','notifications.view']) p
union all select 'support_agent', p from unnest(array['overview.view','transactions.view','users.view','businesses.view','links.view','support.view','support.manage']) p
union all select 'analyst', p from unnest(array['overview.view','transactions.view','users.view','businesses.view','links.view','reports.view','earnings.view','risk.view']) p
;
-- earlier role names keep working
insert into knock.admin_role_permissions select 'admin', permission from knock.admin_role_permissions where role = 'super_admin' on conflict do nothing;
insert into knock.admin_role_permissions select 'finance', permission from knock.admin_role_permissions where role = 'finance_manager' on conflict do nothing;
insert into knock.admin_role_permissions select 'compliance', permission from knock.admin_role_permissions where role = 'risk_officer' on conflict do nothing;
insert into knock.admin_role_permissions select 'support', permission from knock.admin_role_permissions where role = 'support_agent' on conflict do nothing;

create or replace function knock.staff_permissions(p_user uuid) returns text[]
language sql stable as $$
  select coalesce(array_agg(distinct rp.permission order by rp.permission), '{}')
  from knock.staff_roles sr join knock.admin_role_permissions rp on rp.role = sr.role
  join knock.profiles p on p.id = sr.user_id and p.status = 'active'
  where sr.user_id = p_user
$$;

-- The API passes the session's assurance level (Supabase Auth `aal` claim).
-- Admin functions refuse anything below aal2 (MFA), whatever the role.
create or replace function knock.require_staff_perm(p_user uuid, p_perm text, p_aal text) returns void
language plpgsql as $$
begin
  if coalesce(p_aal, '') <> 'aal2' then perform knock.fail('mfa_required', 'sign in with two-factor authentication to use the admin dashboard'); end if;
  if not (p_perm = any(knock.staff_permissions(p_user))) then perform knock.fail('forbidden', 'your staff role does not allow this'); end if;
end $$;

create or replace function knock.saudit(p_actor uuid, p_action text, p_business uuid, p_detail jsonb) returns void
language sql as $$
  insert into knock.audit_log (actor_id, actor_kind, action, business_id, detail) values (p_actor, 'staff', p_action, p_business, p_detail)
$$;

-- Staff verification decisions. 'restricted' goes through dual approval.
create or replace function knock.staff_review_business(p_staff uuid, p_aal text, p_business uuid, p_decision text, p_note text) returns text
language plpgsql as $$
declare b knock.businesses;
begin
  perform knock.require_staff_perm(p_staff, 'businesses.verify', p_aal);
  select * into b from knock.businesses where id = p_business for update;
  if not found then perform knock.fail('not_found', 'business not found'); end if;
  if p_decision not in ('under_review','info_required','verified','rejected') then
    perform knock.fail('bad_request', 'use the restriction request for restrictions');
  end if;
  if b.verification_status not in ('pending','under_review','info_required') and not (b.verification_status = 'rejected' and p_decision = 'under_review') then
    perform knock.fail('bad_state', 'business is ' || b.verification_status);
  end if;
  if p_decision in ('info_required','rejected') and coalesce(trim(p_note), '') = '' then
    perform knock.fail('note_required', 'tell the business what is needed');
  end if;
  if p_decision = 'verified' and b.owner_id = p_staff then perform knock.fail('conflict_of_interest', 'you cannot verify your own business'); end if;
  if p_decision = 'verified' then
    update knock.business_documents set status = 'accepted', reviewed_by = p_staff, reviewed_at = now()
    where business_id = p_business and status = 'uploaded';
  end if;
  perform knock.set_business_verification(p_business, p_decision, p_staff, 'staff', p_note);
  perform knock.saudit(p_staff, 'business.verification.' || p_decision, p_business, jsonb_build_object('note', p_note));
  return p_decision;
end $$;

-- High-impact staff actions: request, then a DIFFERENT staff member approves.
-- action: business.restrict | business.unrestrict | user.restrict | user.unrestrict | list.blacklist
create table knock.admin_action_requests (
  id           uuid primary key default gen_random_uuid(),
  action       text not null check (action in ('business.restrict','business.unrestrict','user.restrict','user.unrestrict','list.blacklist')),
  subject_id   uuid,
  payload      jsonb not null default '{}',
  reason       text not null check (length(reason) >= 10),
  evidence     jsonb not null default '[]',
  requested_by uuid not null references knock.profiles(id),
  decided_by   uuid references knock.profiles(id),
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  check (decided_by is null or decided_by <> requested_by)
);
create unique index admin_action_one_pending on knock.admin_action_requests (action, subject_id) where status = 'pending' and subject_id is not null;

create or replace function knock.staff_request_action(p_staff uuid, p_aal text, p_action text, p_subject uuid, p_reason text, p_evidence jsonb, p_payload jsonb)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  perform knock.require_staff_perm(p_staff, case when p_action like 'business.%' then 'businesses.restrict'
                                                 when p_action like 'user.%' then 'users.restrict' else 'lists.manage' end, p_aal);
  if coalesce(jsonb_array_length(p_evidence), 0) = 0 then perform knock.fail('evidence_required', 'attach the evidence for this action'); end if;
  insert into knock.admin_action_requests (action, subject_id, payload, reason, evidence, requested_by)
  values (p_action, p_subject, coalesce(p_payload, '{}'), p_reason, p_evidence, p_staff) returning id into v_id;
  perform knock.saudit(p_staff, 'admin_action.requested', case when p_action like 'business.%' then p_subject end,
                       jsonb_build_object('request_id', v_id, 'action', p_action, 'subject', p_subject, 'reason', p_reason));
  return v_id;
end $$;

create or replace function knock.staff_decide_action(p_staff uuid, p_aal text, p_request uuid, p_approve boolean, p_note text) returns text
language plpgsql as $$
declare r record; v_perm text;
begin
  select * into r from knock.admin_action_requests where id = p_request for update;
  if not found then perform knock.fail('not_found', 'request not found'); end if;
  v_perm := case when r.action like 'business.%' then 'businesses.restrict' when r.action like 'user.%' then 'users.restrict' else 'lists.approve' end;
  perform knock.require_staff_perm(p_staff, v_perm, p_aal);
  if r.status <> 'pending' then perform knock.fail('bad_state', 'request is ' || r.status); end if;
  if r.requested_by = p_staff then perform knock.fail('second_approver_required', 'a different staff member must approve this'); end if;
  update knock.admin_action_requests set status = case when p_approve then 'approved' else 'rejected' end, decided_by = p_staff, decided_at = now()
  where id = r.id;
  if p_approve then
    if r.action = 'business.restrict' then
      perform knock.set_business_verification(r.subject_id, 'restricted', p_staff, 'staff', r.reason);
    elsif r.action = 'business.unrestrict' then
      perform knock.set_business_verification(r.subject_id, 'verified', p_staff, 'staff', p_note);
    elsif r.action = 'user.restrict' then
      update knock.profiles set status = 'frozen' where id = r.subject_id and kind = 'person';
    elsif r.action = 'user.unrestrict' then
      update knock.profiles set status = 'active' where id = r.subject_id and kind = 'person';
    elsif r.action = 'list.blacklist' then
      update knock.watchlist_entries set status = 'active', approved_by = p_staff, approved_at = now() where id = (r.payload->>'entry_id')::uuid;
    end if;
  elsif r.action = 'list.blacklist' then
    update knock.watchlist_entries set status = 'rejected' where id = (r.payload->>'entry_id')::uuid;
  end if;
  perform knock.saudit(p_staff, 'admin_action.' || case when p_approve then 'approved' else 'rejected' end,
                       case when r.action like 'business.%' then r.subject_id end, jsonb_build_object('request_id', r.id, 'action', r.action, 'note', p_note));
  return case when p_approve then 'approved' else 'rejected' end;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Fraud & risk: cases, rules, lists
-- ---------------------------------------------------------------------------

alter table knock.risk_flags
  add column if not exists category text,
  add column if not exists reason text,
  add column if not exists evidence jsonb,
  add column if not exists assigned_to uuid references knock.profiles(id),
  add column if not exists case_status text not null default 'new',
  add column if not exists resolution_notes text,
  add column if not exists fingerprint text,
  add column if not exists updated_at timestamptz not null default now();
alter table knock.risk_flags drop constraint if exists risk_flags_case_status_check;
alter table knock.risk_flags add constraint risk_flags_case_status_check check (case_status in
  ('new','investigating','info_required','escalated','resolved','closed'));
create unique index if not exists risk_flags_fingerprint_open on knock.risk_flags (fingerprint) where fingerprint is not null and status = 'open';
create index if not exists risk_flags_open on knock.risk_flags (status, severity, created_at desc);

-- Lists. A whitelist entry only lowers ALERT noise for the named rule; it is
-- never read by KYC, limits, verification or AML checks.
create table knock.watchlist_entries (
  id           uuid primary key default gen_random_uuid(),
  list         text not null check (list in ('watch','white','black')),
  subject_kind text not null check (subject_kind in ('user','business','wallet_address','bank_account_hash','email','device','phone')),
  value        text not null,
  reason       text not null check (length(reason) >= 10),
  evidence     jsonb not null default '[]',
  status       text not null default 'active' check (status in ('pending_approval','active','removed','rejected')),
  requested_by uuid not null references knock.profiles(id),
  approved_by  uuid references knock.profiles(id),
  approved_at  timestamptz,
  expires_at   timestamptz,
  created_at   timestamptz not null default now(),
  check (list <> 'black' or status <> 'active' or (approved_by is not null and approved_by <> requested_by))
);
create unique index watchlist_live on knock.watchlist_entries (list, subject_kind, lower(value)) where status in ('pending_approval','active');

create or replace function knock.staff_add_list_entry(p_staff uuid, p_aal text, p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid; v_req uuid; v_list text := p->>'list';
begin
  perform knock.require_staff_perm(p_staff, 'lists.manage', p_aal);
  if v_list = 'black' and coalesce(jsonb_array_length(p->'evidence'), 0) = 0 then
    perform knock.fail('evidence_required', 'a blacklist entry needs supporting evidence');
  end if;
  insert into knock.watchlist_entries (list, subject_kind, value, reason, evidence, status, requested_by, expires_at)
  values (v_list, p->>'subject_kind', p->>'value', p->>'reason', coalesce(p->'evidence','[]'),
          case when v_list = 'black' then 'pending_approval' else 'active' end, p_staff, (p->>'expires_at')::timestamptz)
  returning id into v_id;
  if v_list = 'black' then
    v_req := knock.staff_request_action(p_staff, p_aal, 'list.blacklist', v_id, p->>'reason', p->'evidence', jsonb_build_object('entry_id', v_id));
  end if;
  perform knock.saudit(p_staff, 'list.' || v_list || '.added', null, jsonb_build_object('entry_id', v_id, 'subject_kind', p->>'subject_kind'));
  return jsonb_build_object('id', v_id, 'status', case when v_list = 'black' then 'pending_approval' else 'active' end, 'approval_request', v_req);
end $$;

create or replace function knock.is_blacklisted(p_kind text, p_value text) returns boolean
language sql stable as $$
  select exists (select 1 from knock.watchlist_entries where list = 'black' and status = 'active' and subject_kind = p_kind
                 and lower(value) = lower(p_value) and (expires_at is null or expires_at > now()))
$$;

create or replace function knock.raise_risk(p_holder uuid, p_rule text, p_category text, p_severity text, p_reason text,
                                            p_evidence jsonb, p_fingerprint text, p_subject_kind text default null, p_subject uuid default null)
returns boolean language plpgsql as $$
declare v_ok boolean;
begin
  -- Whitelist suppresses only the alert for that exact rule and holder.
  if exists (select 1 from knock.watchlist_entries w where w.list = 'white' and w.status = 'active'
             and w.subject_kind in ('user','business') and w.value = p_holder::text and w.reason ilike '%' || p_rule || '%') then
    return false;
  end if;
  insert into knock.risk_flags (user_id, rule, category, severity, reason, evidence, fingerprint, subject_kind, subject_id, detail)
  values (p_holder, p_rule, p_category, p_severity, p_reason, p_evidence, p_fingerprint, p_subject_kind, p_subject, p_evidence)
  on conflict (fingerprint) where fingerprint is not null and status = 'open' do nothing
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- Practical rules over Knock's own records. Run on a schedule (and after
-- webhooks). Thresholds are [Guess] and live here in one place.
create or replace function knock.run_risk_rules(p_since timestamptz default now() - interval '24 hours') returns int
language plpgsql as $$
declare n int := 0; r record;
begin
  -- Repeated failed withdrawals (3+ in 24h)
  for r in select user_id, count(*) c, array_agg(knock_reference) refs from knock.provider_withdrawals
           where created_at >= p_since and status in ('rejected','not_submitted','reversed','capacity_unavailable') group by user_id having count(*) >= 3 loop
    if knock.raise_risk(r.user_id, 'repeated_failed_withdrawals', 'withdrawals', 'medium', r.c || ' failed withdrawals in 24 hours',
         jsonb_build_object('references', r.refs), 'rfw:' || r.user_id || ':' || to_char(now(), 'YYYYMMDD')) then n := n + 1; end if;
  end loop;
  -- Rapid in-and-out: a withdrawal within 60 minutes of a completed deposit, for most of it
  for r in select w.user_id, w.id wid, w.knock_reference, d.knock_reference dref from knock.provider_withdrawals w
           join knock.crypto_deposits d on d.user_id = w.user_id and d.status = 'completed'
             and w.created_at between d.completed_at and d.completed_at + interval '60 minutes'
             and w.currency = d.credited_currency and w.amount_minor >= 0.8 * d.customer_net_minor
           where w.created_at >= p_since loop
    if knock.raise_risk(r.user_id, 'rapid_in_out', 'velocity', 'medium', 'Funds withdrawn within an hour of a deposit',
         jsonb_build_object('deposit', r.dref, 'withdrawal', r.knock_reference), 'rio:' || r.wid, 'withdrawal', r.wid) then n := n + 1; end if;
  end loop;
  -- Large single transactions (NGN 5,000,000+ or USD 5,000+)
  for r in select holder_id, id, reference, currency, amount from knock.holder_transactions
           where occurred_at >= p_since and ((currency = 'NGN' and amount >= 500000000) or (currency = 'USD' and amount >= 500000)) loop
    if knock.raise_risk(r.holder_id, 'large_transaction', 'volume', 'low', 'Large transaction ' || r.reference,
         jsonb_build_object('reference', r.reference, 'currency', r.currency, 'amount', r.amount::text), 'lt:' || r.id) then n := n + 1; end if;
  end loop;
  -- Same bank account used by several holders
  for r in select account_number_hash, array_agg(distinct user_id) users from knock.bank_accounts where status = 'active'
           group by account_number_hash having count(distinct user_id) > 1 loop
    if knock.raise_risk(r.users[1], 'shared_bank_account', 'identity', 'medium', 'Bank account linked to ' || array_length(r.users, 1) || ' accounts',
         jsonb_build_object('holders', r.users), 'sba:' || r.account_number_hash) then n := n + 1; end if;
  end loop;
  -- Withdrawals to blacklisted destinations
  for r in select id, user_id, knock_reference, destination_address from knock.provider_withdrawals
           where created_at >= p_since and kind = 'crypto' and knock.is_blacklisted('wallet_address', destination_address) loop
    if knock.raise_risk(r.user_id, 'blacklisted_destination', 'destination', 'high', 'Withdrawal to a blacklisted wallet address',
         jsonb_build_object('withdrawal', r.knock_reference), 'bld:' || r.id, 'withdrawal', r.id) then n := n + 1; end if;
  end loop;
  -- Provider AML / KYT flags on deposits
  for r in select id, user_id, knock_reference, status, flag_reason from knock.crypto_deposits
           where updated_at >= p_since and status in ('flagged','under_review') loop
    if knock.raise_risk(r.user_id, 'provider_aml_flag', 'aml', 'high', 'Provider flagged deposit ' || r.knock_reference,
         jsonb_build_object('deposit', r.knock_reference, 'status', r.status, 'reason', r.flag_reason), 'aml:' || r.id, 'deposit', r.id) then n := n + 1; end if;
  end loop;
  -- Repeated failed payments on one link (5+ in 24h)
  for r in select l.creator_id, l.id, l.reference, count(*) c from knock.payments p join knock.payment_links l on l.id = p.link_id
           where p.created_at >= p_since and p.status = 'failed' group by l.creator_id, l.id, l.reference having count(*) >= 5 loop
    if knock.raise_risk(r.creator_id, 'repeated_payment_failures', 'payments', 'low', r.c || ' failed payments on ' || r.reference,
         jsonb_build_object('link', r.reference), 'rpf:' || r.id || ':' || to_char(now(), 'YYYYMMDD')) then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function knock.staff_update_risk_case(p_staff uuid, p_aal text, p_flag uuid, p jsonb) returns void
language plpgsql as $$
declare f record;
begin
  perform knock.require_staff_perm(p_staff, 'risk.manage', p_aal);
  select * into f from knock.risk_flags where id = p_flag for update;
  if not found then perform knock.fail('not_found', 'alert not found'); end if;
  if p->>'case_status' in ('resolved','closed') and coalesce(trim(p->>'resolution_notes'), '') = '' then
    perform knock.fail('note_required', 'add resolution notes');
  end if;
  update knock.risk_flags set
    case_status = coalesce(p->>'case_status', case_status),
    assigned_to = case when p ? 'assigned_to' then (p->>'assigned_to')::uuid else assigned_to end,
    resolution_notes = coalesce(p->>'resolution_notes', resolution_notes),
    status = case when p->>'case_status' in ('resolved','closed') then 'cleared' else status end,
    updated_at = now()
  where id = p_flag;
  perform knock.saudit(p_staff, 'risk.case.updated', null, jsonb_build_object('flag_id', p_flag) || p);
end $$;

-- ---------------------------------------------------------------------------
-- 12. Support tickets and staff alerts
-- ---------------------------------------------------------------------------

create table knock.support_tickets (
  id          uuid primary key default gen_random_uuid(),
  reference   text not null unique default knock.new_ref('KST'),
  holder_id   uuid not null references knock.profiles(id),
  opened_by   uuid not null references knock.profiles(id),
  subject     text not null check (length(subject) between 3 and 140),
  category    text not null default 'general',
  priority    text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status      text not null default 'open' check (status in ('open','pending_customer','escalated','resolved','closed')),
  assigned_to uuid references knock.profiles(id),
  related_reference text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create table knock.support_messages (
  id         bigserial primary key,
  ticket_id  uuid not null references knock.support_tickets(id),
  author_id  uuid not null references knock.profiles(id),
  author_kind text not null check (author_kind in ('customer','staff')),
  body       text not null check (length(body) between 1 and 4000),
  internal   boolean not null default false,
  at         timestamptz not null default now()
);
create trigger support_messages_immutable before update or delete on knock.support_messages
  for each row execute function knock.forbid_change();

create table knock.admin_alerts (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null,
  severity   text not null check (severity in ('info','warning','critical')),
  title      text not null,
  body       text not null,
  subject_kind text,
  subject_id uuid,
  fingerprint text,
  acknowledged_by uuid references knock.profiles(id),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index admin_alerts_fp on knock.admin_alerts (fingerprint) where fingerprint is not null and acknowledged_at is null;

create or replace function knock.alert_staff(p_kind text, p_sev text, p_title text, p_body text, p_skind text, p_sid uuid, p_fp text)
returns void language sql as $$
  insert into knock.admin_alerts (kind, severity, title, body, subject_kind, subject_id, fingerprint)
  values (p_kind, p_sev, p_title, p_body, p_skind, p_sid, p_fp)
  on conflict (fingerprint) where fingerprint is not null and acknowledged_at is null do nothing
$$;

-- Alerts fire from the records themselves, so no engine had to change.
create or replace function knock.trg_alert_settlement_exception() returns trigger language plpgsql as $$
begin
  perform knock.alert_staff('settlement_failed', 'critical', 'Settlement failed to start',
    format('Trade %s: bank payout did not start (%s). Funds remain with the provider.', new.trade_id, coalesce(new.reason, 'no reason given')),
    'settlement_exception', new.id, 'se:' || new.id);
  return new;
end $$;
create trigger settlement_exceptions_alert after insert on knock.settlement_exceptions
  for each row execute function knock.trg_alert_settlement_exception();

create or replace function knock.trg_alert_recon() returns trigger language plpgsql as $$
begin
  perform knock.alert_staff('reconciliation_mismatch', 'warning', 'Reconciliation mismatch: ' || new.check_name,
    'Subject ' || coalesce(new.subject_ref, '?') || ' differs between Knock and the provider.', 'reconciliation', new.id, 'rc:' || new.fingerprint);
  return new;
end $$;
create trigger reconciliation_records_alert after insert on knock.provider_reconciliation_records
  for each row execute function knock.trg_alert_recon();

create or replace function knock.trg_alert_webhook() returns trigger language plpgsql as $$
begin
  if new.status in ('failed','rejected') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform knock.alert_staff('webhook_failure', case when new.status = 'failed' then 'critical' else 'warning' end,
      'Webhook ' || new.status, coalesce(new.event_type, 'event') || ' ' || new.event_id || ': ' || coalesce(left(new.last_error, 160), 'see processing log'),
      'webhook', new.id, 'wh:' || new.id);
  end if;
  return new;
end $$;
create trigger webhook_events_alert after insert or update of status on knock.webhook_events
  for each row execute function knock.trg_alert_webhook();

create or replace function knock.trg_alert_risk() returns trigger language plpgsql as $$
begin
  if new.severity = 'high' then
    perform knock.alert_staff('risk', 'critical', 'High-severity risk alert: ' || new.rule, coalesce(new.reason, new.rule), 'risk_flag', new.id, 'rf:' || new.id);
  end if;
  return new;
end $$;
create trigger risk_flags_alert after insert on knock.risk_flags for each row execute function knock.trg_alert_risk();

create or replace function knock.trg_alert_verification() returns trigger language plpgsql as $$
begin
  if new.to_status = 'pending' then
    perform knock.alert_staff('kyc', 'info', 'Business verification submitted',
      (select legal_name from knock.businesses where id = new.business_id) || ' is waiting for review.', 'business', new.business_id, 'kyc:' || new.id);
  end if;
  return new;
end $$;
create trigger business_verification_alert after insert on knock.business_verification_events
  for each row execute function knock.trg_alert_verification();

-- ---------------------------------------------------------------------------
-- 13. Admin read models
-- ---------------------------------------------------------------------------

create or replace function knock.admin_overview(p_staff uuid, p_aal text, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable as $$
declare v jsonb;
begin
  perform knock.require_staff_perm(p_staff, 'overview.view', p_aal);
  with t as (select * from knock.holder_transactions where occurred_at >= p_from and occurred_at < p_to and category <> 'split_distribution'),
  rev as (
    select l.currency, -sum(l.amount) as amount from knock.journal_lines l
    join knock.ledger_accounts a on a.id = l.account_id and a.purpose = 'fee_revenue'
    join knock.journal_entries e on e.id = l.entry_id where e.created_at >= p_from and e.created_at < p_to group by l.currency
  )
  select jsonb_build_object(
    'volume', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text, 'count', c)) from
                (select currency, sum(amount) s, count(*) c from t where state = 'succeeded' group by currency) x), '[]'),
    'counts', jsonb_build_object('succeeded', (select count(*) from t where state = 'succeeded'), 'pending', (select count(*) from t where state = 'pending'),
                                 'failed', (select count(*) from t where state = 'failed')),
    'users', (select count(*) from knock.profiles where kind = 'person'),
    'businesses', (select count(*) from knock.businesses),
    'active_businesses', (select count(distinct holder_id) from t join knock.profiles p on p.id = t.holder_id and p.kind = 'business' where state = 'succeeded'),
    'verified_businesses', (select count(*) from knock.businesses where verification_status = 'verified'),
    'payment_links', (select count(*) from knock.payment_links),
    'link_collections', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text)) from
                (select currency, sum(amount) s from t where category = 'payment_link_collection' and state = 'succeeded' group by currency) x), '[]'),
    'split_distributions', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text, 'count', c)) from
                (select a.currency, sum(a.net_share) s, count(*) c from knock.split_allocations a join knock.payment_links l on l.id = a.link_id
                 where l.link_type = 'split' and a.created_at >= p_from and a.created_at < p_to group by a.currency) x), '[]'),
    'provider_fees', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', s::text)) from
                (select currency, sum(amount) s from knock.provider_fee_records where source = 'provider_reported' and created_at >= p_from and created_at < p_to group by currency) x), '[]'),
    'knock_revenue', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'amount', amount::text)) from rev), '[]'),
    'pending_settlements', (select count(*) from knock.settlements where status in ('awaiting_payout','processing')),
    'failed_settlements', (select count(*) from knock.settlements where status in ('failed_to_start','needs_review')),
    'open_risk_alerts', (select count(*) from knock.risk_flags where status = 'open'),
    'pending_verifications', (select count(*) from knock.businesses where verification_status in ('pending','under_review')),
    'open_alerts', (select count(*) from knock.admin_alerts where acknowledged_at is null)
  ) into v;
  return v;
end $$;

-- Where the money is, by owner type, straight from ledger balances.
-- Customer and business funds are liabilities (owed to them), never revenue.
create or replace function knock.admin_earnings(p_staff uuid, p_aal text, p_from timestamptz, p_to timestamptz) returns jsonb
language plpgsql stable as $$
declare v jsonb;
begin
  perform knock.require_staff_perm(p_staff, 'earnings.view', p_aal);
  with b as (
    select ab.currency, ab.purpose, coalesce(p.kind, 'system') as holder_kind, ab.balance
    from knock.account_balances ab left join knock.profiles p on p.id = ab.owner_id
  ), period as (
    select a.purpose, l.currency, sum(l.amount) as debits_minus_credits
    from knock.journal_lines l join knock.ledger_accounts a on a.id = l.account_id
    join knock.journal_entries e on e.id = l.entry_id
    where e.created_at >= p_from and e.created_at < p_to and a.purpose in ('fee_revenue','provider_fee_expense')
    group by 1, 2
  )
  select jsonb_build_object(
    'positions', coalesce((select jsonb_agg(jsonb_build_object('currency', currency, 'bucket', bucket, 'amount', amt::text) order by bucket, currency) from (
        select currency, case
          when purpose like 'user_%' and holder_kind = 'person' then 'customer_funds'
          when purpose like 'user_%' and holder_kind = 'business' then 'business_funds'
          when purpose = 'link_collection' then 'awaiting_distribution'
          when purpose in ('provider_wallet','provider_clearing') then 'provider_held'
          when purpose = 'settlement_bank' then 'knock_bank'
          when purpose = 'fee_revenue' then 'knock_revenue_total'
          when purpose = 'provider_fee_expense' then 'provider_costs_total'
          when purpose = 'recovery_receivable' then 'recoveries_owed'
          else purpose end as bucket, sum(balance) amt
        from b group by 1, 2 having sum(balance) <> 0) x), '[]'),
    'period', coalesce((select jsonb_agg(jsonb_build_object('currency', currency,
        'kind', case purpose when 'fee_revenue' then 'knock_revenue' else 'provider_costs' end,
        'amount', (case purpose when 'fee_revenue' then -debits_minus_credits else debits_minus_credits end)::text)) from period), '[]'),
    'fee_breakdown', coalesce((select jsonb_agg(jsonb_build_object('fee_type', fee_type, 'source', source, 'currency', currency, 'amount', s::text)) from
        (select fee_type, source, currency, sum(amount) s from knock.provider_fee_records where created_at >= p_from and created_at < p_to group by 1,2,3) x), '[]'),
    'reversals', (select count(*) from knock.payments where status = 'reversed' and updated_at >= p_from and updated_at < p_to)
                 + (select count(*) from knock.provider_withdrawals where status = 'reversed' and updated_at >= p_from and updated_at < p_to),
    'operating_expenses', null,
    'notes', jsonb_build_array(
      'Customer and business funds are amounts Knock owes to account holders. They are never revenue.',
      'Knock revenue = Knock service fees posted to fee_revenue in the ledger.',
      'Provider-reported fees (deposit processing, conversion spread, settlement markup, withdrawal fees) are charged by the provider and recorded separately.',
      'Operating expenses are not recorded in the Knock ledger, so net earnings here are before operating expenses.')
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 14. RLS: members read their businesses; only the service role writes
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['feature_flags','business_categories','business_verification_requirements','business_settings','businesses',
    'business_role_permissions','business_members','business_member_permissions','business_documents','business_representatives',
    'business_verification_events','business_payout_requests','admin_role_permissions','admin_action_requests','watchlist_entries',
    'support_tickets','support_messages','admin_alerts'] loop
    execute format('alter table knock.%I enable row level security', t);
    execute format('revoke all on knock.%I from public', t);
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'auth' and p.proname = 'uid') then
    execute $p$create policy member_business on knock.businesses for select using (knock.business_can(auth.uid(), id, 'dashboard.view'))$p$;
    execute $p$create policy member_rows on knock.business_members for select using (user_id = auth.uid() or knock.business_can(auth.uid(), business_id, 'team.manage'))$p$;
    execute $p$create policy member_payouts on knock.business_payout_requests for select using (knock.business_can(auth.uid(), business_id, 'transactions.view'))$p$;
    execute $p$create policy member_deposits on knock.crypto_deposits for select using (knock.business_can(auth.uid(), user_id, 'transactions.view'))$p$;
    execute $p$create policy member_withdrawals on knock.provider_withdrawals for select using (knock.business_can(auth.uid(), user_id, 'transactions.view'))$p$;
    execute $p$create policy member_links on knock.payment_links for select using (knock.business_can(auth.uid(), creator_id, 'dashboard.view'))$p$;
    execute $p$create policy member_notifications on knock.notifications for select using (knock.business_can(auth.uid(), user_id, 'dashboard.view'))$p$;
    execute $p$create policy read_flags on knock.feature_flags for select using (true)$p$;
    execute $p$create policy read_categories on knock.business_categories for select using (true)$p$;
  end if;
end $$;
