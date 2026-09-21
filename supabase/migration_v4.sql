-- ============================================================================
-- migration_v4.sql — signup-based voter flow (no codes)
-- Apply AFTER migration_v3.sql on the live database.
-- Idempotent: safe to re-run.
--
-- New model:
--   Voter signs up (Supabase Auth) -> fills registration form (fields per
--   admin settings) -> uploads ID photo if required -> admin verifies if
--   manual review is on -> votes once -> gets XXXX-XXXX receipt.
-- The old code/token flow is left untouched.
-- ============================================================================

-- ---------- 1. voter_registrations ----------
create table if not exists public.voter_registrations (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references public.elections(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text,
  class text,
  enrollment_id text,
  status text not null default 'pending'
    check (status in ('pending', 'verified', 'rejected')),
  voted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (election_id, user_id)
);
alter table public.voter_registrations enable row level security;

-- Owner can read their own registration. NO owner insert/update/delete:
-- all writes go through register_voter() RPC so status/voted_at cannot be
-- forged by the voter.
drop policy if exists "voter_registrations owner read" on public.voter_registrations;
create policy "voter_registrations owner read"
  on public.voter_registrations for select to authenticated
  using (auth.uid() = user_id);
drop policy if exists "voter_registrations admin all" on public.voter_registrations;
create policy "voter_registrations admin all"
  on public.voter_registrations for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------- 2. election_settings (admin-controlled registration fields) ----------
create table if not exists public.election_settings (
  election_id uuid primary key references public.elections(id) on delete cascade,
  require_name boolean not null default true,
  require_class boolean not null default false,
  require_enrollment_id boolean not null default false,
  require_id_upload boolean not null default false,
  manual_review boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.election_settings enable row level security;

-- Voters need to read settings to render the registration form.
drop policy if exists "election_settings public read" on public.election_settings;
create policy "election_settings public read"
  on public.election_settings for select to anon, authenticated
  using (true);
drop policy if exists "election_settings admin all" on public.election_settings;
create policy "election_settings admin all"
  on public.election_settings for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Default settings row for elections (created lazily by helpers too).
create or replace function public.ensure_election_settings(p_election_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.election_settings (election_id)
  values (p_election_id)
  on conflict (election_id) do nothing;
end;
$$;

-- ---------- 3. candidates: photo + manifesto ----------
alter table public.candidates
  add column if not exists image_url text;
alter table public.candidates
  add column if not exists manifesto text;

-- ---------- 4. id_uploads: bind to user for v2 flow ----------
alter table public.id_uploads
  add column if not exists user_id uuid references auth.users(id) on delete cascade;
create index if not exists id_uploads_user_election_idx
  on public.id_uploads (election_id, user_id);

-- id_verifications: record who the ID belongs to in v2 flow
alter table public.id_verifications
  add column if not exists user_id uuid references auth.users(id) on delete set null;

-- votes: link to registration for v2 flow (token_hash stays for v1)
alter table public.votes
  add column if not exists registration_id uuid
    references public.voter_registrations(id) on delete cascade;
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'votes_registration_unique'
  ) then
    alter table public.votes
      add constraint votes_registration_unique unique (registration_id);
  end if;
end $$;

-- ---------- 5. storage slot helper + policies for v2 (authenticated) ----------
create or replace function public.id_upload_slot_open_v2(p_path text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.id_uploads u
    where u.path = p_path
      and u.user_id = auth.uid()
      and u.used = false
      and u.expires_at > now()
  );
$$;
revoke all on function public.id_upload_slot_open_v2(text) from public;
grant execute on function public.id_upload_slot_open_v2(text) to authenticated;

drop policy if exists "voter v2 id upload" on storage.objects;
create policy "voter v2 id upload"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open_v2(name)
  );

drop policy if exists "voter v2 id select own pending" on storage.objects;
create policy "voter v2 id select own pending"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open_v2(name)
  );

drop policy if exists "voter v2 id delete own pending" on storage.objects;
create policy "voter v2 id delete own pending"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open_v2(name)
  );

-- ---------- 6. voter RPCs ----------

-- Public ballot data: election + settings + candidates.
create or replace function public.get_ballot(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e jsonb; v_s jsonb; v_c jsonb; v_r jsonb;
begin
  perform public.ensure_election_settings(p_election_id);
  select jsonb_build_object(
      'id', e.id, 'title', e.title, 'status', e.status,
      'results_published', e.results_published
    )
    into v_e
    from public.elections e where e.id = p_election_id;
  if v_e is null then
    return jsonb_build_object('ok', false, 'error', 'Election not found');
  end if;
  select jsonb_build_object(
      'require_name', s.require_name,
      'require_class', s.require_class,
      'require_enrollment_id', s.require_enrollment_id,
      'require_id_upload', s.require_id_upload,
      'manual_review', s.manual_review
    )
    into v_s
    from public.election_settings s where s.election_id = p_election_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'position', c.position,
      'photo_url', c.photo_url, 'image_url', c.image_url,
      'manifesto', c.manifesto
    ) order by c.position, c.name), '[]'::jsonb)
    into v_c
    from public.candidates c where c.election_id = p_election_id;
  if auth.uid() is not null then
    select jsonb_build_object(
        'status', r.status,
        'voted', r.voted_at is not null,
        'name', r.name, 'class', r.class, 'enrollment_id', r.enrollment_id
      )
      into v_r
      from public.voter_registrations r
      where r.election_id = p_election_id and r.user_id = auth.uid();
  end if;
  return jsonb_build_object(
    'ok', true, 'election', v_e, 'settings', v_s,
    'candidates', v_c, 'registration', v_r
  );
end;
$$;
revoke all on function public.get_ballot(uuid) from public;
grant execute on function public.get_ballot(uuid) to anon, authenticated;

-- Register / update own voter profile. Status/voted_at are server-controlled.
create or replace function public.register_voter(
  p_election_id uuid,
  p_name text default null,
  p_class text default null,
  p_enrollment_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_s public.election_settings%rowtype;
  v_status text := 'pending';
  v_estatus text;
  v_reg_id uuid;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Please sign in first');
  end if;
  select e.status into v_estatus from public.elections e where e.id = p_election_id;
  if v_estatus is null then
    return jsonb_build_object('ok', false, 'error', 'Election not found');
  end if;
  if v_estatus <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Registration is closed for this election');
  end if;
  perform public.ensure_election_settings(p_election_id);
  select * into v_s from public.election_settings where election_id = p_election_id;

  if v_s.require_name and nullif(trim(coalesce(p_name, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Name is required');
  end if;
  if v_s.require_class and nullif(trim(coalesce(p_class, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Class is required');
  end if;
  if v_s.require_enrollment_id and nullif(trim(coalesce(p_enrollment_id, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Enrollment ID is required');
  end if;

  if not v_s.manual_review then
    v_status := 'verified';
  end if;

  -- a voter who already voted cannot re-register
  if exists (select 1 from public.voter_registrations
              where election_id = p_election_id
                and user_id = auth.uid()
                and voted_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'You have already voted');
  end if;

  insert into public.voter_registrations
    (election_id, user_id, name, class, enrollment_id, status)
  values
    (p_election_id, auth.uid(),
     nullif(trim(coalesce(p_name, '')), ''),
     nullif(trim(coalesce(p_class, '')), ''),
     nullif(trim(coalesce(p_enrollment_id, '')), ''),
     v_status)
  on conflict (election_id, user_id) do update set
    name = excluded.name,
    class = excluded.class,
    enrollment_id = excluded.enrollment_id,
    -- a rejected voter who re-registers goes back to pending for review
    status = case
      when public.voter_registrations.status = 'rejected' then 'pending'
      when public.voter_registrations.status = 'pending' and not v_s.manual_review then 'verified'
      else public.voter_registrations.status
    end
  where public.voter_registrations.voted_at is null
  returning id into v_reg_id;

  return jsonb_build_object('ok', true, 'status', v_status, 'registration_id', v_reg_id);
end;
$$;
revoke all on function public.register_voter(uuid, text, text, text) from public;
grant execute on function public.register_voter(uuid, text, text, text) to authenticated;

-- Opaque upload slot bound to (election, user). Old unused slots are cleared.
create or replace function public.request_id_upload_v2(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_reg public.voter_registrations%rowtype;
  v_path text;
  v_s public.election_settings%rowtype;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Please sign in first');
  end if;
  select * into v_reg from public.voter_registrations
   where election_id = p_election_id and user_id = auth.uid();
  if v_reg.id is null then
    return jsonb_build_object('ok', false, 'error', 'Please complete registration first');
  end if;
  if v_reg.voted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'You have already voted');
  end if;
  perform public.ensure_election_settings(p_election_id);
  select * into v_s from public.election_settings where election_id = p_election_id;
  if not v_s.require_id_upload then
    return jsonb_build_object('ok', false, 'error', 'ID upload is not required for this election');
  end if;

  -- clear previous unused slots (re-upload = fresh slot).
  -- NOTE: the old storage object is intentionally left in the bucket:
  -- Supabase forbids direct deletes on storage.objects ("use the Storage
  -- API instead"), so orphaned ID photos are swept via the Storage API
  -- by an admin cleanup, not here. The slot row deletion is what
  -- invalidates the old upload path.
  delete from public.id_uploads
   where election_id = p_election_id
     and user_id = auth.uid()
     and used = false;

  v_path := 'v2/' || encode(gen_random_bytes(16), 'hex');
  insert into public.id_uploads (election_id, user_id, path, expires_at)
  values (p_election_id, auth.uid(), v_path, now() + interval '30 minutes');

  return jsonb_build_object('ok', true, 'path', v_path);
end;
$$;
revoke all on function public.request_id_upload_v2(uuid) from public;
grant execute on function public.request_id_upload_v2(uuid) to authenticated;

-- Cast a vote as a verified registered voter. One vote per (election, user).
create or replace function public.cast_vote_v2(
  p_election_id uuid,
  p_monitor_id uuid default null,
  p_cr_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_reg public.voter_registrations%rowtype;
  v_status text;
  v_s public.election_settings%rowtype;
  v_upath text;
  v_uid uuid;
  v_mime text;
  v_size bigint;
  v_identity text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Please sign in first');
  end if;

  select * into v_reg from public.voter_registrations
   where election_id = p_election_id and user_id = auth.uid()
   for update;
  if v_reg.id is null then
    return jsonb_build_object('ok', false, 'error', 'Please complete registration first');
  end if;
  if v_reg.voted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'You have already voted');
  end if;
  if v_reg.status <> 'verified' then
    return jsonb_build_object('ok', false, 'error', 'Your registration is pending verification');
  end if;

  select e.status into v_status from public.elections e where e.id = p_election_id;
  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is closed');
  end if;

  perform public.ensure_election_settings(p_election_id);
  select * into v_s from public.election_settings where election_id = p_election_id;

  if v_s.require_id_upload then
    select u.id, u.path into v_uid, v_upath
      from public.id_uploads u
     where u.election_id = p_election_id
       and u.user_id = auth.uid()
       and u.used = false
       and u.expires_at > now()
     order by u.created_at desc
     limit 1;
    if v_uid is null then
      return jsonb_build_object('ok', false, 'error', 'ID photo is required — please upload your ID card photo');
    end if;
    select o.metadata ->> 'mimetype', (o.metadata ->> 'size')::bigint
      into v_mime, v_size
      from storage.objects o
     where o.bucket_id = 'id-cards' and o.name = v_upath;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID photo not uploaded yet — please upload your ID card photo');
    end if;
    if v_mime is null or v_mime not like 'image/%' then
      return jsonb_build_object('ok', false, 'error', 'ID photo must be an image file (JPG/PNG/WebP)');
    end if;
    if v_size is null or v_size > 6291456 then
      return jsonb_build_object('ok', false, 'error', 'ID photo is too large (max 6 MB)');
    end if;
  end if;

  if p_monitor_id is not null and not exists (
    select 1 from public.candidates
     where id = p_monitor_id and election_id = p_election_id and position = 'monitor'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid Monitor candidate');
  end if;
  if p_cr_id is not null and not exists (
    select 1 from public.candidates
     where id = p_cr_id and election_id = p_election_id and position = 'cr'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid CR candidate');
  end if;
  if p_monitor_id is null and p_cr_id is null then
    return jsonb_build_object('ok', false, 'error', 'Select at least one candidate');
  end if;

  loop
    v_identity := upper(encode(gen_random_bytes(4), 'hex'));
    v_identity := substring(v_identity, 1, 4) || '-' || substring(v_identity, 5, 4);
    exit when not exists (select 1 from public.votes where voter_identity = v_identity);
  end loop;

  insert into public.votes
    (election_id, registration_id, monitor_candidate_id, cr_candidate_id, voter_identity)
  values
    (p_election_id, v_reg.id, p_monitor_id, p_cr_id, v_identity);

  if v_s.require_id_upload then
    insert into public.id_verifications (election_id, user_id, path)
    values (p_election_id, auth.uid(), v_upath);
    update public.id_uploads set used = true where id = v_uid;
  end if;

  update public.voter_registrations set voted_at = now() where id = v_reg.id;

  return jsonb_build_object('ok', true, 'voter_identity', v_identity);

exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'You have already voted');
end;
$$;
revoke all on function public.cast_vote_v2(uuid, uuid, uuid) from public;
grant execute on function public.cast_vote_v2(uuid, uuid, uuid) to authenticated;

-- ---------- 7. admin RPCs ----------

create or replace function public.admin_update_settings(
  p_election_id uuid,
  p_require_name boolean default null,
  p_require_class boolean default null,
  p_require_enrollment_id boolean default null,
  p_require_id_upload boolean default null,
  p_manual_review boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_admin();
  perform public.ensure_election_settings(p_election_id);
  update public.election_settings set
    require_name = coalesce(p_require_name, require_name),
    require_class = coalesce(p_require_class, require_class),
    require_enrollment_id = coalesce(p_require_enrollment_id, require_enrollment_id),
    require_id_upload = coalesce(p_require_id_upload, require_id_upload),
    manual_review = coalesce(p_manual_review, manual_review)
  where election_id = p_election_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_update_settings(uuid, boolean, boolean, boolean, boolean, boolean) from public;
grant execute on function public.admin_update_settings(uuid, boolean, boolean, boolean, boolean, boolean) to authenticated;

create or replace function public.admin_list_registrations(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_rows jsonb;
begin
  perform public.require_admin();
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id,
      'email', u.email,
      'name', r.name,
      'class', r.class,
      'enrollment_id', r.enrollment_id,
      'status', r.status,
      'voted', r.voted_at is not null,
      'created_at', r.created_at,
      'id_path', (select iu.path from public.id_uploads iu
                   where iu.election_id = r.election_id
                     and iu.user_id = r.user_id
                   order by iu.created_at desc limit 1)
    ) order by r.created_at), '[]'::jsonb)
    into v_rows
    from public.voter_registrations r
    join auth.users u on u.id = r.user_id
   where r.election_id = p_election_id;
  return v_rows;
end;
$$;
revoke all on function public.admin_list_registrations(uuid) from public;
grant execute on function public.admin_list_registrations(uuid) to authenticated;

create or replace function public.admin_verify_registration(
  p_registration_id uuid,
  p_approved boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_admin();
  update public.voter_registrations
     set status = case when p_approved then 'verified' else 'rejected' end
   where id = p_registration_id and voted_at is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Registration not found or already voted');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_verify_registration(uuid, boolean) from public;
grant execute on function public.admin_verify_registration(uuid, boolean) to authenticated;

-- Candidate with image + manifesto (extends admin_add_candidate).
create or replace function public.admin_add_candidate(
  p_election_id uuid,
  p_name text,
  p_position text,
  p_photo_url text default null,
  p_image_url text default null,
  p_manifesto text default null
)
returns public.candidates
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row public.candidates;
begin
  perform public.require_admin();
  insert into public.candidates (election_id, name, position, photo_url, image_url, manifesto)
  values (p_election_id, p_name, p_position, p_photo_url, p_image_url, p_manifesto)
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.admin_add_candidate(uuid, text, text, text, text, text) from public;
grant execute on function public.admin_add_candidate(uuid, text, text, text, text, text) to authenticated;

create or replace function public.admin_update_candidate(
  p_candidate_id uuid,
  p_name text default null,
  p_position text default null,
  p_photo_url text default null,
  p_image_url text default null,
  p_manifesto text default null
)
returns public.candidates
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row public.candidates;
begin
  perform public.require_admin();
  update public.candidates set
    name = coalesce(p_name, name),
    position = coalesce(p_position, position),
    photo_url = coalesce(p_photo_url, photo_url),
    image_url = coalesce(p_image_url, image_url),
    manifesto = coalesce(p_manifesto, manifesto)
  where id = p_candidate_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.admin_update_candidate(uuid, text, text, text, text, text) from public;
grant execute on function public.admin_update_candidate(uuid, text, text, text, text, text) to authenticated;

-- ---------- 8. lock down id_uploads / id_verifications for v2 ----------
-- (v1 rows keep working; v2 rows are bound to user_id.)

-- Owner can read their own uploads (needed for re-upload flow status).
drop policy if exists "id_uploads owner read" on public.id_uploads;
create policy "id_uploads owner read"
  on public.id_uploads for select to authenticated
  using (auth.uid() = user_id);

-- ---------- 9. admin_update_election: allow partial updates ----------
-- The original required all 4 args. Now status/results/id-card can be
-- updated independently (null = leave unchanged).
create or replace function public.admin_update_election(
  p_election_id uuid,
  p_status text default null,
  p_results_published boolean default null,
  p_require_id_card boolean default null
)
returns public.elections
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row public.elections;
begin
  perform public.require_admin();
  if p_status is not null and p_status not in ('draft', 'open', 'closed') then
    raise exception 'Invalid status';
  end if;
  update public.elections
  set status = coalesce(p_status, status),
      results_published = coalesce(p_results_published, results_published),
      require_id_card = coalesce(p_require_id_card, require_id_card)
  where id = p_election_id
  returning * into v_row;
  if not found then raise exception 'Election not found'; end if;
  return v_row;
end;
$$;
revoke all on function public.admin_update_election(uuid, text, boolean, boolean) from public;
grant execute on function public.admin_update_election(uuid, text, boolean, boolean) to authenticated;

-- ---------- 10. id_uploads / id_verifications: allow user-bound (v2) rows ----------
-- v1 rows use token_hash, v2 rows use user_id. Exactly one must be set.
alter table public.id_uploads alter column token_hash drop not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'id_uploads_binding_check') then
    alter table public.id_uploads
      add constraint id_uploads_binding_check
      check (token_hash is not null or user_id is not null);
  end if;
end $$;

alter table public.id_verifications alter column token_hash drop not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'id_verifications_binding_check') then
    alter table public.id_verifications
      add constraint id_verifications_binding_check
      check (token_hash is not null or user_id is not null);
  end if;
  -- token_hash unique only makes sense for v1; keep it but allow multiple nulls
  -- (Postgres unique already allows multiple nulls).
end $$;

-- ---------- 11. votes: allow registration-bound (v2) rows ----------
alter table public.votes alter column token_hash drop not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'votes_binding_check') then
    alter table public.votes
      add constraint votes_binding_check
      check (token_hash is not null or registration_id is not null);
  end if;
end $$;

-- ---------- 12. public open-elections list ----------
create or replace function public.list_open_elections()
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'title', e.title
    ) order by e.created_at desc), '[]'::jsonb)
  from public.elections e
  where e.status = 'open';
$$;
revoke all on function public.list_open_elections() from public;
grant execute on function public.list_open_elections() to anon, authenticated;

-- ---------- 13. fix pack (2026-09-21) ----------
-- c) Remove the legacy 4-arg admin_add_candidate overload. The 6-arg version
--    below is a strict superset (extra params default null); keeping both
--    made PostgREST return 300 PGRST203 on every candidate create.
drop function if exists public.admin_add_candidate(uuid, text, text, text);

-- a) Deleting a user must not break on id_verifications binding check:
--    verification rows belong to the user, cascade them instead of SET NULL.
alter table public.id_verifications drop constraint if exists id_verifications_user_id_fkey;
alter table public.id_verifications add constraint id_verifications_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete cascade;

-- b) Admins need to SEE id-card photos for manual verification, and to
--    remove them when moderating. Scoped to the id-cards bucket only.
drop policy if exists "admin id-cards select" on storage.objects;
create policy "admin id-cards select"
  on storage.objects for select to authenticated
  using (bucket_id = 'id-cards' and public.is_admin());
drop policy if exists "admin id-cards delete" on storage.objects;
create policy "admin id-cards delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'id-cards' and public.is_admin());

-- ---------- admin_stats v4 (2026-09-21) ----------
-- Registration-based stats. Supersedes the v1 code-based version
-- (codes_total/codes_used) which belonged to the pre-issued-code flow.
create or replace function public.admin_stats(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare v_regs int; v_pending int; v_votes int;
begin
  perform public.require_admin();
  select count(*) into v_regs from public.voter_registrations where election_id = p_election_id;
  select count(*) into v_pending from public.voter_registrations where election_id = p_election_id and status = 'pending';
  select count(*) into v_votes from public.votes where election_id = p_election_id;
  return jsonb_build_object(
    'registrations', v_regs, 'pending', v_pending, 'votes', v_votes
  );
end;
$$;
