-- Business-owner sign-up and post-sign-up verification.
--
-- Sign-up is light: a Supabase Auth user (email + password) calls
-- register_business_owner once, which creates their person profile and their
-- business (unverified). They can use the dashboard straight away; every
-- money movement stays behind require_business_money (verified only).
-- Verification later asks for: entity type and CAC number, CAC certificate,
-- MEMAT (limited companies), proof of address, and one or two directors with
-- NIN and BVN.

-- ---------------------------------------------------------------------------
-- Entity type and requirements
-- ---------------------------------------------------------------------------
alter table knock.businesses add column entity_type text check (entity_type in ('business_name','limited_company','incorporated_trustees'));
alter table knock.business_verification_requirements add column entity_type text;
do $$
declare c text;
begin
  for c in select conname from pg_constraint where conrelid = 'knock.business_verification_requirements'::regclass and contype = 'u' loop
    execute format('alter table knock.business_verification_requirements drop constraint %I', c);
  end loop;
end $$;
create unique index business_verification_requirements_key on knock.business_verification_requirements
  (country, coalesce(category, ''), doc_type, coalesce(entity_type, ''));

update knock.business_verification_requirements set label = 'CAC certificate of registration (BN or RC)'
  where country = 'NG' and doc_type = 'registration_certificate';
update knock.business_verification_requirements set label = 'ID of each director (NIN slip, international passport or driver''s licence)'
  where country = 'NG' and doc_type = 'representative_id';
insert into knock.business_verification_requirements (country, category, doc_type, label, required, min_representatives, entity_type) values
  ('NG', null, 'memat', 'Memorandum and Articles of Association (MEMAT)', true, 1, 'limited_company'),
  ('NG', null, 'status_report', 'CAC status report (Form CAC 1.1) showing directors', false, 1, 'limited_company'),
  ('NG', null, 'constitution', 'Constitution of the trustees', true, 1, 'incorporated_trustees');

insert into knock.business_settings values
  ('max_directors', '2', 'Directors a business adds for verification (one or two)')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Directors' identity. Full NIN and BVN are NOT stored: the API passes them to
-- the identity provider (not chosen yet) and Knock keeps the last 4 digits and
-- the provider's result. Until a provider is connected the check stays
-- 'awaiting_provider' and Knock's reviewers see the last 4 digits only.
-- ---------------------------------------------------------------------------
alter table knock.business_representatives
  add column phone          text,
  add column date_of_birth  date,
  add column nin_last4      text check (nin_last4 ~ '^[0-9]{4}$'),
  add column bvn_last4      text check (bvn_last4 ~ '^[0-9]{4}$'),
  add column identity_check text not null default 'not_started'
    check (identity_check in ('not_started','awaiting_provider','verified','failed'));

create or replace function knock.add_business_director(p_user uuid, p_business uuid, p jsonb) returns uuid
language plpgsql as $$
declare b knock.businesses; v_id uuid; v_max int; v_nin text := regexp_replace(coalesce(p->>'nin',''), '\s', '', 'g');
        v_bvn text := regexp_replace(coalesce(p->>'bvn',''), '\s', '', 'g'); v_dob date;
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status in ('pending','under_review','verified') then perform knock.fail('locked', 'contact support to change directors'); end if;
  v_max := coalesce((select (value #>> '{}')::int from knock.business_settings where key = 'max_directors'), 2);
  if (select count(*) from knock.business_representatives where business_id = p_business and status = 'active') >= v_max then
    perform knock.fail('limit_exceeded', format('add up to %s directors', v_max));
  end if;
  if length(trim(coalesce(p->>'full_name',''))) < 3 then perform knock.fail('bad_request', 'enter the director''s full legal name'); end if;
  if v_nin !~ '^[0-9]{11}$' then perform knock.fail('invalid_nin', 'NIN must be 11 digits'); end if;
  if v_bvn !~ '^[0-9]{11}$' then perform knock.fail('invalid_bvn', 'BVN must be 11 digits'); end if;
  begin v_dob := (p->>'date_of_birth')::date; exception when others then v_dob := null; end;
  if v_dob is null or v_dob > (current_date - interval '18 years') or v_dob < date '1900-01-01' then
    perform knock.fail('bad_request', 'enter a valid date of birth (directors must be 18 or older)');
  end if;
  if coalesce(p->>'phone','') !~ '^\+?[0-9 ]{10,16}$' then perform knock.fail('bad_request', 'enter the director''s phone number'); end if;
  insert into knock.business_representatives (business_id, full_name, role_title, ownership_bps, email, phone, date_of_birth,
                                              nin_last4, bvn_last4, identity_check)
  values (p_business, trim(p->>'full_name'), coalesce(nullif(trim(p->>'role_title'),''), 'Director'), (p->>'ownership_bps')::int,
          nullif(lower(trim(p->>'email')),''), p->>'phone', v_dob, right(v_nin, 4), right(v_bvn, 4), 'awaiting_provider')
  returning id into v_id;
  -- Audit without the numbers.
  perform knock.baudit(p_user, p_business, 'business.director.added', jsonb_build_object('representative_id', v_id));
  return v_id;
end $$;

create or replace function knock.remove_business_representative(p_user uuid, p_business uuid, p_rep uuid) returns void
language plpgsql as $$
declare b knock.businesses;
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status in ('pending','under_review','verified') then perform knock.fail('locked', 'contact support to change directors'); end if;
  update knock.business_representatives set status = 'removed' where id = p_rep and business_id = p_business and status = 'active';
  if not found then perform knock.fail('not_found', 'director not found'); end if;
  perform knock.baudit(p_user, p_business, 'business.director.removed', jsonb_build_object('representative_id', p_rep));
end $$;

create or replace function knock.set_business_registration(p_user uuid, p_business uuid, p jsonb) returns void
language plpgsql as $$
declare b knock.businesses; v_no text := upper(regexp_replace(coalesce(p->>'registration_number',''), '\s', '', 'g'));
begin
  b := knock.require_business(p_user, p_business, 'verification.manage');
  if b.verification_status in ('pending','under_review','verified') then perform knock.fail('locked', 'contact support to change registration details'); end if;
  if p->>'entity_type' not in ('business_name','limited_company','incorporated_trustees') then perform knock.fail('bad_request', 'choose how the business is registered'); end if;
  if b.country = 'NG' and v_no !~ '^(RC|BN|IT)?[0-9]{4,10}$' then perform knock.fail('bad_request', 'enter the CAC number, e.g. RC1234567 or BN1234567'); end if;
  update knock.businesses set entity_type = p->>'entity_type', registration_number = v_no,
         legal_name = coalesce(nullif(trim(p->>'legal_name'),''), legal_name), updated_at = now()
  where id = p_business;
  perform knock.baudit(p_user, p_business, 'business.registration.updated', jsonb_build_object('entity_type', p->>'entity_type', 'registration_number', v_no));
end $$;

-- What is still missing before the business can submit (replaces 000500's).
create or replace function knock.business_verification_checklist(p_business uuid) returns jsonb
language sql stable as $$
  with b as (select * from knock.businesses where id = p_business),
  req as (
    select r.* from knock.business_verification_requirements r, b
    where r.country = b.country and (r.category is null or r.category = b.category)
      and (r.entity_type is null or r.entity_type = b.entity_type)
  ),
  docs as (
    select req.doc_type, req.label, req.required,
           exists (select 1 from knock.business_documents d where d.business_id = p_business and d.doc_type = req.doc_type
                   and d.status in ('uploaded','accepted')) as provided,
           (select d.status from knock.business_documents d where d.business_id = p_business and d.doc_type = req.doc_type
            and d.status <> 'superseded' order by d.created_at desc limit 1) as doc_status
    from req
  ),
  reps as (
    select count(*) filter (where nin_last4 is not null and bvn_last4 is not null) as with_identity, count(*) as total
    from knock.business_representatives where business_id = p_business and status = 'active'
  )
  select jsonb_build_object(
    'documents', coalesce((select jsonb_agg(to_jsonb(docs) order by required desc, label) from docs), '[]'),
    'representatives_required', greatest(coalesce((select max(min_representatives) from req), 0), 1),
    'representatives', (select with_identity from reps),
    'representatives_max', coalesce((select (value #>> '{}')::int from knock.business_settings where key = 'max_directors'), 2),
    'registration_complete', (select b.entity_type is not null and b.registration_number is not null from b),
    'profile_complete', (select b.legal_name is not null and b.email is not null and b.category is not null
                                and b.entity_type is not null and b.registration_number is not null from b),
    'ready', (select bool_and(provided) from docs where required) is not false
             and (select with_identity from reps) >= greatest(coalesce((select max(min_representatives) from req), 0), 1)
             and (select b.entity_type is not null and b.registration_number is not null from b)
  )
$$;

-- ---------------------------------------------------------------------------
-- Owner sign-up
-- ---------------------------------------------------------------------------
create or replace function knock.slug_handle(p_text text, p_max int) returns text language sql immutable as $$
  select left(trim(both '_' from regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '_', 'g')), p_max)
$$;

-- p_user is the Supabase Auth user id (from the verified JWT). Called once,
-- right after sign-up. p: {full_name, business_name, email, phone, category, country}
create or replace function knock.register_business_owner(p_user uuid, p jsonb) returns jsonb
language plpgsql as $$
declare u knock.profiles; v_user text; v_handle text; v_base text; i int := 0; r jsonb;
        v_email text := lower(trim(coalesce(p->>'email',''))); v_phone text := trim(coalesce(p->>'phone',''));
begin
  if length(trim(coalesce(p->>'full_name',''))) < 3 then perform knock.fail('bad_request', 'enter your full name'); end if;
  if length(trim(coalesce(p->>'business_name',''))) < 2 then perform knock.fail('bad_request', 'enter your business name'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform knock.fail('bad_request', 'enter a valid email'); end if;
  if v_phone !~ '^\+?[0-9 ]{10,16}$' then perform knock.fail('bad_request', 'enter a valid phone number'); end if;

  select * into u from knock.profiles where id = p_user for update;
  if found then
    if u.kind <> 'person' then perform knock.fail('forbidden', 'sign in as a person'); end if;
    if exists (select 1 from knock.businesses where owner_id = p_user) then
      perform knock.fail('already_registered', 'this account already owns a business; log in instead');
    end if;
  else
    v_base := coalesce(nullif(knock.slug_handle(p->>'full_name', 14), ''), 'owner');
    if length(v_base) < 3 then v_base := v_base || '_kb'; end if;
    v_user := v_base;
    while exists (select 1 from knock.profiles where lower(username) = v_user) loop
      i := i + 1; v_user := left(v_base, 14) || (100 + floor(random() * 9900))::int::text;
      if i > 20 then perform knock.fail('internal', 'could not create a username'); end if;
    end loop;
    insert into knock.profiles (id, username, display_name, kind, kyc_tier, status)
    values (p_user, v_user, trim(p->>'full_name'), 'person', 0, 'active');
  end if;

  v_base := coalesce(nullif(knock.slug_handle(p->>'business_name', 16), ''), 'business');
  if length(v_base) < 3 then v_base := v_base || '_biz'; end if;
  v_handle := v_base; i := 0;
  while exists (select 1 from knock.profiles where lower(username) = v_handle) loop
    i := i + 1; v_handle := left(v_base, 16) || (10 + floor(random() * 990))::int::text;
    if i > 20 then perform knock.fail('internal', 'could not create a handle'); end if;
  end loop;

  r := knock.create_business(p_user, jsonb_build_object(
         'handle', v_handle, 'legal_name', trim(p->>'business_name'), 'category', coalesce(nullif(p->>'category',''), 'other'),
         'country', coalesce(nullif(upper(p->>'country'),''), 'NG'), 'email', v_email, 'phone', v_phone));
  perform knock.baudit(p_user, (r->>'id')::uuid, 'business.owner_signed_up', '{}'::jsonb);
  return r;
end $$;

-- Who may use the business web app: owners and active team members only.
create or replace function knock.business_app_access(p_user uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'allowed', exists (select 1 from knock.business_members where user_id = p_user and status = 'active'),
    'owner', exists (select 1 from knock.businesses where owner_id = p_user),
    'invited', exists (select 1 from knock.business_members where user_id = p_user and status = 'invited'))
$$;
