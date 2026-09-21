-- ============================================================
-- Class Monitor / CR Election — Supabase schema (CONSOLIDATED, clean install)
--
-- This single file installs the FULL backend on an EMPTY Supabase project:
-- base schema + migrations v2, v3, v4, v5, in order. Paste the whole file
-- into Dashboard > SQL Editor and Run once.
--
-- Equivalent to applying, in order: schema.sql, migration_v2.sql,
-- migration_v3.sql, migration_v4.sql, migration_v5.sql on a fresh project.
--
-- SECURITY MODEL
-- * Voters sign in with Supabase Auth (email+password, anon key) and can
--   ONLY call the whitelisted RPCs (register_voter, get_ballot,
--   request_id_upload_v2, confirm_id_upload_v2, cast_vote_v2, ...).
--   Direct table reads/writes are blocked by RLS.
-- * Admins sign in with email+password. Every admin_* RPC checks the
--   caller's profiles.is_admin flag server-side. NO service_role key in app.
-- * claim_first_admin() is DISABLED (raises). First admin is promoted via
--   SQL only:  update profiles set is_admin=true where email='...';
-- * No UPDATE policy exists on profiles: self-promotion is impossible.
-- * ID slots: opaque random v2/ paths, single-use, 15-min expiry, image
--   MIME + 1..6 MB enforced server-side in id_upload_ready_v2().
-- * Votes: cast_vote_v2() locks the registration row, UNIQUE
--   (registration_id) makes double-vote impossible; p_idempotency_key
--   replays the original XXXX-XXXX receipt on lost responses.
-- ============================================================


-- ================= BASE SCHEMA (v1/v2 base: tables, RLS, auth trigger, admin helpers) [schema.sql] =================

-- ============================================================
-- Class Monitor / CR Election — Supabase schema (v2, secure)
-- Paste this whole file into Supabase Dashboard > SQL Editor and Run.
--
-- SECURITY MODEL
-- * Voters use the anon key and can ONLY call 3 RPCs:
--     validate_token, request_id_upload, cast_vote
--   Direct table reads/writes are blocked by RLS.
-- * Admins sign in with email+password (Supabase Auth). Every admin
--   action goes through an admin_* RPC that checks the caller's
--   profiles.is_admin flag. There is NO service_role key in the app.
-- * First admin bootstrap: sign in, the app calls claim_first_admin(),
--   which promotes you only if no admin exists yet.
--   (Dashboard > Authentication > "Allow new signups" should be OFF.)
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Tables ----------

create table if not exists elections (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  status text not null default 'draft'
    check (status in ('draft', 'open', 'closed')),
  results_published boolean not null default false,
  -- When true, every voter must upload their school ID card before voting.
  -- Toggled by the admin; off by default.
  require_id_card boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists candidates (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  name text not null,
  position text not null check (position in ('monitor', 'cr')),
  photo_url text,
  created_at timestamptz not null default now()
);

-- Only SHA-256 hashes of voting codes are stored here. Plain codes are
-- shown once to the admin at generation time and never saved anywhere.
create table if not exists voter_tokens (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null unique,
  used boolean not null default false,
  used_at timestamptz,
  created_at timestamptz not null default now()
);

-- One row per voter (per election). token_hash is UNIQUE so a code can
-- never produce two vote rows, even under double-clicks / retries.
-- voter_identity is the unique public receipt shown to the voter after voting.
-- NOTE: identity evidence (ID card) is stored in id_verifications, NOT here,
-- so the ballot row carries no link to the voter's identity document.
create table if not exists votes (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null unique,
  monitor_candidate_id uuid references candidates(id) on delete set null,
  cr_candidate_id uuid references candidates(id) on delete set null,
  voter_identity text unique,
  created_at timestamptz not null default now(),
  check (monitor_candidate_id is not null or cr_candidate_id is not null)
);

-- Admin accounts: one row per Supabase Auth user.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- One-time ID-card upload slots. A voter must obtain a slot (bound to
-- their voting code) before the storage upload is allowed.
create table if not exists id_uploads (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null,
  path text not null unique,
  used boolean not null default false,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

-- Identity evidence, kept SEPARATE from the votes table.
create table if not exists id_verifications (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null unique,
  path text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_candidates_election on candidates(election_id);
create index if not exists idx_tokens_election on voter_tokens(election_id);
create index if not exists idx_votes_election on votes(election_id);
create index if not exists idx_uploads_token on id_uploads(token_hash);
create index if not exists idx_idverif_election on id_verifications(election_id);

-- ---------- Row Level Security ----------

alter table elections enable row level security;
alter table candidates enable row level security;
alter table voter_tokens enable row level security;
alter table votes enable row level security;
alter table profiles enable row level security;
alter table id_uploads enable row level security;
alter table id_verifications enable row level security;

-- Voters (anon key) may read election info + candidate list only.
drop policy if exists "anon read elections" on elections;
create policy "anon read elections"
  on elections for select to anon using (true);

drop policy if exists "anon read candidates" on candidates;
create policy "anon read candidates"
  on candidates for select to anon using (true);

-- No policies on voter_tokens / votes / id_uploads / id_verifications:
-- direct reads and writes are fully blocked. Voting happens ONLY through
-- the RPC functions below, which run with SECURITY DEFINER.

-- Users can read/update only their own profile row.
drop policy if exists "owner read profile" on profiles;
create policy "owner read profile"
  on profiles for select to authenticated using (auth.uid() = id);

-- NOTE: there is intentionally NO update policy on profiles. Letting users
-- update their own row would let them set is_admin = true (self-promotion).
-- Admin flags are managed only inside SECURITY DEFINER functions.

-- Auto-create a profile row whenever an auth user is created.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Admin helpers ----------

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public, extensions
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  );
$$;

create or replace function public.require_admin()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
end;
$$;

-- "Am I an admin?" — for the frontend after sign-in.
create or replace function am_i_admin()
returns boolean
language sql
security definer
set search_path = public, extensions
stable
as $$ select public.is_admin(); $$;

-- First-admin bootstrap: promotes the caller only if NO admin exists yet.
-- Safe because public signups must be disabled in the dashboard.
-- Admin bootstrap is DISABLED in production. The real admin is provisioned
-- via Supabase Auth directly. This stub stays so old clients fail closed
-- with a clear message instead of hitting a missing function.
create or replace function claim_first_admin()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return jsonb_build_object('ok', false, 'error', 'Admin bootstrap is disabled. Contact the system administrator.');
end;
$$;

-- ---------- Private storage bucket for ID card photos ----------
-- No broad anon access. Uploads are allowed ONLY to a path that has a
-- live, unused upload slot (see request_id_upload), must be an image,
-- and must be <= 6 MB. Admins can read via signed URLs; voters can
-- never list, read, overwrite others' files, or delete.

insert into storage.buckets (id, name, public)
values ('id-cards', 'id-cards', false)
on conflict (id) do nothing;

drop policy if exists "anon upload id cards" on storage.objects;
drop policy if exists "anon replace id cards" on storage.objects;
drop policy if exists "voter id upload" on storage.objects;
drop policy if exists "voter id re-upload" on storage.objects;
drop policy if exists "admin read id cards" on storage.objects;

-- RLS-safe slot check: storage policies run as anon, and public.id_uploads has
-- RLS with no anon policy, so the check must run as SECURITY DEFINER.
-- Returns only a boolean; leaks no slot data (paths are 128-bit random).
create or replace function public.id_upload_slot_open(p_path text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.id_uploads u
    where u.path = p_path
      and u.used = false
      and u.expires_at > now()
  );
$$;

revoke all on function public.id_upload_slot_open(text) from public;
grant execute on function public.id_upload_slot_open(text) to anon;

create policy "voter id upload"
  on storage.objects for insert to anon
  with check (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

-- NOTE: file-type/size are NOT checked here. Supabase storage evaluates the
-- INSERT policy before it populates objects.metadata, so metadata-based checks
-- always fail at upload time. Type/size are enforced in cast_vote() instead.

-- Lets a voter replace ONLY their own pending upload (same slot path,
-- before the vote is cast). No access to anyone else's files.
create policy "voter id re-upload"
  on storage.objects for update to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  )
  with check (
    bucket_id = 'id-cards'
  );

-- Scoped SELECT so the storage server's bulk remove() can list the voter's own
-- pending file before deleting it. Same slot-bound scope as insert/delete.
drop policy if exists "voter id select own pending" on storage.objects;
create policy "voter id select own pending"
  on storage.objects for select to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

-- Lets a voter delete ONLY their own pending upload (open slot path, before
-- the vote is cast). Used for re-upload as remove + upload fresh, because the
-- storage server's upsert conflicts with RLS even under a permissive policy.
drop policy if exists "voter id delete own pending" on storage.objects;
create policy "voter id delete own pending"
  on storage.objects for delete to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

create policy "admin read id cards"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'id-cards'
    and public.is_admin()
  );

-- Admins may delete ID card files (used by orphan cleanup).
drop policy if exists "admin delete id cards" on storage.objects;
create policy "admin delete id cards"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'id-cards'
    and public.is_admin()
  );

-- ---------- RPC: validate a voting code (voter) ----------

create or replace function validate_token(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_title text;
  v_status text;
  v_require_id boolean;
begin
  select t.election_id, e.title, e.status, e.require_id_card
    into v_election_id, v_title, v_status, v_require_id
  from voter_tokens t
  join elections e on e.id = t.election_id
  where t.token_hash = p_token_hash
    and t.used = false;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is not open right now');
  end if;

  return jsonb_build_object(
    'ok', true,
    'election_id', v_election_id,
    'title', v_title,
    'require_id_card', v_require_id
  );
end;
$$;

-- ---------- RPC: request a one-time ID upload slot (voter) ----------

create or replace function request_id_upload(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_status text;
  v_require_id boolean;
  v_id uuid;
  v_path text;
  v_expires timestamptz;
begin
  select t.election_id
    into v_election_id
  from voter_tokens t
  where t.token_hash = p_token_hash
    and t.used = false;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  select e.status, e.require_id_card
    into v_status, v_require_id
  from elections e where e.id = v_election_id;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is not open right now');
  end if;

  if not v_require_id then
    return jsonb_build_object('ok', false, 'error', 'ID verification is not enabled for this election');
  end if;

  -- Idempotent: reuse the voter's live slot if one exists.
  select u.id, u.path, u.expires_at
    into v_id, v_path, v_expires
  from id_uploads u
  where u.token_hash = p_token_hash
    and u.used = false
    and u.expires_at > now()
  order by u.created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true, 'upload_id', v_id, 'path', v_path, 'expires_at', v_expires
    );
  end if;

  -- Random, unguessable path — never derived from the voting code.
  v_id := gen_random_uuid();
  v_path := v_election_id::text || '/' || encode(gen_random_bytes(16), 'hex') || '.jpg';
  v_expires := now() + interval '15 minutes';

  insert into id_uploads (id, election_id, token_hash, path, expires_at)
  values (v_id, v_election_id, p_token_hash, v_path, v_expires);

  return jsonb_build_object(
    'ok', true, 'upload_id', v_id, 'path', v_path, 'expires_at', v_expires
  );
end;
$$;

-- ---------- RPC: cast a vote (atomic, one-time) ----------

-- Drop all older signatures.
drop function if exists cast_vote(text, uuid, uuid);
drop function if exists cast_vote(text, uuid, uuid, text);

create or replace function cast_vote(
  p_token_hash text,
  p_monitor_id uuid,
  p_cr_id uuid,
  p_upload_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_status text;
  v_require_id boolean;
  v_path text;
  v_mime text;
  v_size bigint;
  v_identity text;
begin
  -- Lock the token row so two concurrent requests cannot both pass.
  select t.election_id
    into v_election_id
  from voter_tokens t
  where t.token_hash = p_token_hash
    and t.used = false
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  select e.status, e.require_id_card
    into v_status, v_require_id
  from elections e where e.id = v_election_id;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is closed');
  end if;

  -- ID verification: the upload slot must belong to this code, be live,
  -- and unused, AND the photo file must actually exist in storage.
  -- (A requested slot alone must never satisfy the ID requirement.)
  if v_require_id then
    if p_upload_id is null then
      return jsonb_build_object('ok', false, 'error', 'ID card upload is required for this election');
    end if;
    select u.path
      into v_path
    from id_uploads u
    where u.id = p_upload_id
      and u.token_hash = p_token_hash
      and u.used = false
      and u.expires_at > now();
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID upload missing or expired — please upload your ID again');
    end if;
    -- Highest security: a requested slot alone is not enough. The ID photo file
    -- must actually exist in storage, be an image, and respect the size limit.
    -- (Type/size are enforced here because storage RLS runs before the storage
    --  server populates objects.metadata.)
    select o.metadata ->> 'mimetype', (o.metadata ->> 'size')::bigint
      into v_mime, v_size
    from storage.objects o
    where o.bucket_id = 'id-cards'
      and o.name = v_path;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID photo not uploaded yet — please upload your ID card photo');
    end if;
    if v_mime is null or v_mime not like 'image/%' then
      return jsonb_build_object('ok', false, 'error', 'ID photo must be an image file (JPG/PNG/WebP)');
    end if;
    if v_size is null or v_size > 6291456 then
      return jsonb_build_object('ok', false, 'error', 'ID photo is too large (max 6 MB)');
    end if;
    update id_uploads u
      set used = true
      where u.id = p_upload_id;
  end if;

  if p_monitor_id is not null and not exists (
    select 1 from candidates
    where id = p_monitor_id
      and election_id = v_election_id
      and position = 'monitor'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid Monitor candidate');
  end if;

  if p_cr_id is not null and not exists (
    select 1 from candidates
    where id = p_cr_id
      and election_id = v_election_id
      and position = 'cr'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid CR candidate');
  end if;

  if p_monitor_id is null and p_cr_id is null then
    return jsonb_build_object('ok', false, 'error', 'Select at least one candidate');
  end if;

  -- Unique voter identity (public receipt), format XXXX-XXXX.
  loop
    v_identity := upper(encode(gen_random_bytes(4), 'hex'));
    v_identity := substring(v_identity, 1, 4) || '-' || substring(v_identity, 5, 4);
    exit when not exists (select 1 from votes where voter_identity = v_identity);
  end loop;

  insert into votes (election_id, token_hash, monitor_candidate_id, cr_candidate_id, voter_identity)
  values (v_election_id, p_token_hash, p_monitor_id, p_cr_id, v_identity);

  -- Identity evidence lives in its own table, away from the ballot row.
  if v_require_id then
    insert into id_verifications (election_id, token_hash, path)
    values (v_election_id, p_token_hash, v_path);
  end if;

  update voter_tokens
  set used = true, used_at = now()
  where token_hash = p_token_hash;

  return jsonb_build_object('ok', true, 'voter_identity', v_identity);

exception when unique_violation then
  -- token_hash is UNIQUE: a second insert for the same code is impossible.
  return jsonb_build_object('ok', false, 'error', 'This code has already voted');
end;
$$;

-- ---------- Admin RPCs (every one enforces require_admin) ----------

create or replace function admin_list_elections()
returns setof elections
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select * from elections order by created_at desc;
end;
$$;

create or replace function admin_create_election(p_title text)
returns elections
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row elections;
begin
  perform public.require_admin();
  if p_title is null or btrim(p_title) = '' then
    raise exception 'Title is required';
  end if;
  insert into elections (title) values (btrim(p_title))
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function admin_update_election(
  p_election_id uuid,
  p_status text,
  p_results_published boolean,
  p_require_id_card boolean
)
returns elections
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row elections;
begin
  perform public.require_admin();
  if p_status not in ('draft', 'open', 'closed') then
    raise exception 'Invalid status';
  end if;
  update elections
  set status = p_status,
      results_published = p_results_published,
      require_id_card = p_require_id_card
  where id = p_election_id
  returning * into v_row;
  if not found then raise exception 'Election not found'; end if;
  return v_row;
end;
$$;

create or replace function admin_delete_election(p_election_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.require_admin();
  delete from elections where id = p_election_id;
end;
$$;

create or replace function admin_list_candidates(p_election_id uuid)
returns setof candidates
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select * from candidates
    where election_id = p_election_id order by position, name;
end;
$$;

-- NOTE: the old 4-arg admin_add_candidate(uuid,text,text,text) was removed
-- (2026-09-21). The 6-arg version in migration_v4.sql supersedes it; keeping
-- both overloads made PostgREST return 300 PGRST203 "could not choose".
-- Fresh installs must NOT recreate the 4-arg overload.

create or replace function admin_delete_candidate(p_candidate_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.require_admin();
  delete from candidates where id = p_candidate_id;
end;
$$;

create or replace function admin_stats(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare v_total int; v_used int; v_votes int;
begin
  perform public.require_admin();
  select count(*) into v_total from voter_tokens where election_id = p_election_id;
  select count(*) into v_used from voter_tokens where election_id = p_election_id and used = true;
  select count(*) into v_votes from votes where election_id = p_election_id;
  return jsonb_build_object(
    'codes_total', v_total, 'codes_used', v_used, 'votes', v_votes
  );
end;
$$;

create or replace function admin_tally(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare v_out jsonb;
begin
  perform public.require_admin();
  select coalesce(jsonb_agg(t order by t.votes desc), '[]'::jsonb) into v_out
  from (
    select c.id as candidate_id, c.name, c.position,
      count(v.id)::bigint as votes
    from candidates c
    left join votes v on v.election_id = c.election_id
      and (v.monitor_candidate_id = c.id or v.cr_candidate_id = c.id)
    where c.election_id = p_election_id
    group by c.id, c.name, c.position
  ) t;
  return v_out;
end;
$$;

-- p_hashes: array of SHA-256 hex digests (admin's browser hashes the
-- plain codes; plain codes never touch the server).
create or replace function admin_generate_codes(p_election_id uuid, p_hashes text[])
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_count int := 0;
begin
  perform public.require_admin();
  if not exists (select 1 from elections where id = p_election_id) then
    raise exception 'Election not found';
  end if;
  if coalesce(array_length(p_hashes, 1), 0) > 500 then
    raise exception 'Too many codes (max 500 per batch)';
  end if;
  insert into voter_tokens (election_id, token_hash)
  select p_election_id, h from unnest(p_hashes) as h
  on conflict (token_hash) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Identity-evidence review: returns paths only (no token hashes).
-- The admin frontend turns each path into a short-lived signed URL.
create or replace function admin_list_id_verifications(p_election_id uuid)
returns table (verification_id uuid, path text, created_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select v.id, v.path, v.created_at
    from id_verifications v
    where v.election_id = p_election_id
    order by v.created_at desc;
end;
$$;

-- Deletes expired, unused upload slots and returns their file paths.
-- The admin frontend then removes the actual files via the Storage API
-- (deleting the DB row alone would orphan the file on disk).
create or replace function admin_cleanup_orphan_uploads()
returns text[]
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_paths text[];
begin
  perform public.require_admin();
  select array_agg(path) into v_paths
  from id_uploads
  where used = false and expires_at < now();
  delete from id_uploads where used = false and expires_at < now();
  return coalesce(v_paths, '{}'::text[]);
end;
$$;

-- ---------- Public results view (only when published) ----------

create or replace view public_results as
select
  e.id as election_id,
  e.title as election_title,
  c.position,
  c.id as candidate_id,
  c.name as candidate_name,
  c.photo_url,
  count(v.id)::bigint as vote_count
from elections e
join candidates c on c.election_id = e.id
left join votes v on v.election_id = e.id
  and (v.monitor_candidate_id = c.id or v.cr_candidate_id = c.id)
where e.results_published = true
group by e.id, e.title, c.position, c.id, c.name, c.photo_url;

grant select on public_results to anon;

-- ---------- Execute grants (deny-by-default) ----------

-- Voter RPCs: anon only.
revoke all on function validate_token(text) from public;
grant execute on function validate_token(text) to anon;

revoke all on function request_id_upload(text) from public;
grant execute on function request_id_upload(text) to anon;

revoke all on function cast_vote(text, uuid, uuid, uuid) from public;
revoke all on function cast_vote(text, uuid, uuid, uuid) from anon;
revoke all on function cast_vote(text, uuid, uuid, uuid) from authenticated;
-- v7 hardening: legacy token-based cast_vote is obsolete (superseded by
-- cast_vote_v2) and must not be invokable via PostgREST by anyone.

-- Auth helpers + admin RPCs: authenticated only
-- (each admin_* RPC re-checks require_admin() internally).
revoke all on function am_i_admin() from public;
grant execute on function am_i_admin() to authenticated;

revoke all on function claim_first_admin() from public;
grant execute on function claim_first_admin() to authenticated;

revoke all on function admin_list_elections() from public;
grant execute on function admin_list_elections() to authenticated;

revoke all on function admin_create_election(text) from public;
grant execute on function admin_create_election(text) to authenticated;

revoke all on function admin_update_election(uuid, text, boolean, boolean) from public;
grant execute on function admin_update_election(uuid, text, boolean, boolean) to authenticated;

revoke all on function admin_delete_election(uuid) from public;
grant execute on function admin_delete_election(uuid) to authenticated;

revoke all on function admin_list_candidates(uuid) from public;
grant execute on function admin_list_candidates(uuid) to authenticated;

revoke all on function admin_delete_candidate(uuid) from public;
grant execute on function admin_delete_candidate(uuid) to authenticated;

revoke all on function admin_stats(uuid) from public;
grant execute on function admin_stats(uuid) to authenticated;

revoke all on function admin_tally(uuid) from public;
grant execute on function admin_tally(uuid) to authenticated;

revoke all on function admin_generate_codes(uuid, text[]) from public;
grant execute on function admin_generate_codes(uuid, text[]) to authenticated;

revoke all on function admin_list_id_verifications(uuid) from public;
grant execute on function admin_list_id_verifications(uuid) to authenticated;

revoke all on function admin_cleanup_orphan_uploads() from public;
grant execute on function admin_cleanup_orphan_uploads() to authenticated;


-- ================= MIGRATION v2 (Supabase Auth voter accounts, registration flow, storage v1) [migration_v2.sql] =================

-- ============================================================
-- Migration v2 — secure admin auth + hardened ID uploads
-- Run ONCE on a database that already has v1 schema applied.
-- Safe to re-run: every statement is idempotent.
-- Supabase Dashboard > SQL Editor me paste karke Run karo.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- New tables ----------

create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists id_uploads (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null,
  path text not null unique,
  used boolean not null default false,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists id_verifications (
  id uuid primary key default gen_random_uuid(),
  election_id uuid not null references elections(id) on delete cascade,
  token_hash text not null unique,
  path text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_uploads_token on id_uploads(token_hash);
create index if not exists idx_idverif_election on id_verifications(election_id);

alter table profiles enable row level security;
alter table id_uploads enable row level security;
alter table id_verifications enable row level security;

drop policy if exists "owner read profile" on profiles;
create policy "owner read profile"
  on profiles for select to authenticated using (auth.uid() = id);

-- No update policy on profiles (self-promotion risk). Admin flags are
-- managed only inside SECURITY DEFINER functions.
drop policy if exists "owner update profile" on profiles;

-- (no policies on id_uploads / id_verifications: RPC-only)

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Admin helpers ----------

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public, extensions
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  );
$$;

create or replace function public.require_admin()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
end;
$$;

create or replace function am_i_admin()
returns boolean
language sql
security definer
set search_path = public, extensions
stable
as $$ select public.is_admin(); $$;

-- claim_first_admin() is PERMANENTLY DISABLED (bootstrap removed 2026-09-21).
-- The first admin is promoted via SQL only:
--   update profiles set is_admin = true where email = '...';
create or replace function claim_first_admin()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return jsonb_build_object('ok', false, 'error', 'Admin bootstrap is disabled. Contact the system administrator.');
end;
$$;

-- ---------- Storage policies (replace the permissive v1 ones) ----------

drop policy if exists "anon upload id cards" on storage.objects;
drop policy if exists "anon replace id cards" on storage.objects;
drop policy if exists "voter id upload" on storage.objects;
drop policy if exists "voter id re-upload" on storage.objects;
drop policy if exists "admin read id cards" on storage.objects;

create policy "voter id upload"
  on storage.objects for insert to anon
  with check (
    bucket_id = 'id-cards'
    and exists (
      select 1 from public.id_uploads u
      where u.path = name
        and u.used = false
        and u.expires_at > now()
    )
    and (metadata ->> 'mimetype') like 'image/%'
    and (metadata ->> 'size')::bigint <= 6291456
  );

create policy "voter id re-upload"
  on storage.objects for update to anon
  using (
    bucket_id = 'id-cards'
    and exists (
      select 1 from public.id_uploads u
      where u.path = name
        and u.used = false
        and u.expires_at > now()
    )
  )
  with check (
    bucket_id = 'id-cards'
    and (metadata ->> 'mimetype') like 'image/%'
    and (metadata ->> 'size')::bigint <= 6291456
  );

create policy "admin read id cards"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'id-cards'
    and public.is_admin()
  );

-- Admins may delete ID card files (used by orphan cleanup).
drop policy if exists "admin delete id cards" on storage.objects;
create policy "admin delete id cards"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'id-cards'
    and public.is_admin()
  );

-- ---------- Voter RPCs ----------

create or replace function request_id_upload(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_status text;
  v_require_id boolean;
  v_id uuid;
  v_path text;
  v_expires timestamptz;
begin
  select t.election_id
    into v_election_id
  from voter_tokens t
  where t.token_hash = p_token_hash
    and t.used = false;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  select e.status, e.require_id_card
    into v_status, v_require_id
  from elections e where e.id = v_election_id;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is not open right now');
  end if;

  if not v_require_id then
    return jsonb_build_object('ok', false, 'error', 'ID verification is not enabled for this election');
  end if;

  select u.id, u.path, u.expires_at
    into v_id, v_path, v_expires
  from id_uploads u
  where u.token_hash = p_token_hash
    and u.used = false
    and u.expires_at > now()
  order by u.created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true, 'upload_id', v_id, 'path', v_path, 'expires_at', v_expires
    );
  end if;

  v_id := gen_random_uuid();
  v_path := v_election_id::text || '/' || encode(gen_random_bytes(16), 'hex') || '.jpg';
  v_expires := now() + interval '15 minutes';

  insert into id_uploads (id, election_id, token_hash, path, expires_at)
  values (v_id, v_election_id, p_token_hash, v_path, v_expires);

  return jsonb_build_object(
    'ok', true, 'upload_id', v_id, 'path', v_path, 'expires_at', v_expires
  );
end;
$$;

-- Drop v1 signatures, install v2.
drop function if exists cast_vote(text, uuid, uuid);
drop function if exists cast_vote(text, uuid, uuid, text);

create or replace function cast_vote(
  p_token_hash text,
  p_monitor_id uuid,
  p_cr_id uuid,
  p_upload_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_status text;
  v_require_id boolean;
  v_path text;
  v_identity text;
begin
  select t.election_id
    into v_election_id
  from voter_tokens t
  where t.token_hash = p_token_hash
    and t.used = false
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  select e.status, e.require_id_card
    into v_status, v_require_id
  from elections e where e.id = v_election_id;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is closed');
  end if;

  if v_require_id then
    if p_upload_id is null then
      return jsonb_build_object('ok', false, 'error', 'ID card upload is required for this election');
    end if;
    update id_uploads u
      set used = true
      where u.id = p_upload_id
        and u.token_hash = p_token_hash
        and u.used = false
        and u.expires_at > now()
      returning u.path into v_path;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID upload missing or expired — please upload your ID again');
    end if;
  end if;

  if p_monitor_id is not null and not exists (
    select 1 from candidates
    where id = p_monitor_id
      and election_id = v_election_id
      and position = 'monitor'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid Monitor candidate');
  end if;

  if p_cr_id is not null and not exists (
    select 1 from candidates
    where id = p_cr_id
      and election_id = v_election_id
      and position = 'cr'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid CR candidate');
  end if;

  if p_monitor_id is null and p_cr_id is null then
    return jsonb_build_object('ok', false, 'error', 'Select at least one candidate');
  end if;

  loop
    v_identity := upper(encode(gen_random_bytes(4), 'hex'));
    v_identity := substring(v_identity, 1, 4) || '-' || substring(v_identity, 5, 4);
    exit when not exists (select 1 from votes where voter_identity = v_identity);
  end loop;

  insert into votes (election_id, token_hash, monitor_candidate_id, cr_candidate_id, voter_identity)
  values (v_election_id, p_token_hash, p_monitor_id, p_cr_id, v_identity);

  if v_require_id then
    insert into id_verifications (election_id, token_hash, path)
    values (v_election_id, p_token_hash, v_path);
  end if;

  update voter_tokens
  set used = true, used_at = now()
  where token_hash = p_token_hash;

  return jsonb_build_object('ok', true, 'voter_identity', v_identity);

exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'This code has already voted');
end;
$$;

-- Identity evidence moves out of the votes row.
alter table votes drop column if exists id_card_path;

-- ---------- Admin RPCs ----------

create or replace function admin_list_elections()
returns setof elections
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select * from elections order by created_at desc;
end;
$$;

create or replace function admin_create_election(p_title text)
returns elections
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row elections;
begin
  perform public.require_admin();
  if p_title is null or btrim(p_title) = '' then
    raise exception 'Title is required';
  end if;
  insert into elections (title) values (btrim(p_title))
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function admin_update_election(
  p_election_id uuid,
  p_status text,
  p_results_published boolean,
  p_require_id_card boolean
)
returns elections
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row elections;
begin
  perform public.require_admin();
  if p_status not in ('draft', 'open', 'closed') then
    raise exception 'Invalid status';
  end if;
  update elections
  set status = p_status,
      results_published = p_results_published,
      require_id_card = p_require_id_card
  where id = p_election_id
  returning * into v_row;
  if not found then raise exception 'Election not found'; end if;
  return v_row;
end;
$$;

create or replace function admin_delete_election(p_election_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.require_admin();
  delete from elections where id = p_election_id;
end;
$$;

create or replace function admin_list_candidates(p_election_id uuid)
returns setof candidates
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select * from candidates
    where election_id = p_election_id order by position, name;
end;
$$;

create or replace function admin_add_candidate(
  p_election_id uuid,
  p_name text,
  p_position text,
  p_photo_url text default null
)
returns candidates
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_row candidates;
begin
  perform public.require_admin();
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Name is required';
  end if;
  if p_position not in ('monitor', 'cr') then
    raise exception 'Invalid position';
  end if;
  insert into candidates (election_id, name, position, photo_url)
  values (p_election_id, btrim(p_name), p_position, nullif(btrim(p_photo_url), ''))
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function admin_delete_candidate(p_candidate_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.require_admin();
  delete from candidates where id = p_candidate_id;
end;
$$;

create or replace function admin_stats(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare v_total int; v_used int; v_votes int;
begin
  perform public.require_admin();
  select count(*) into v_total from voter_tokens where election_id = p_election_id;
  select count(*) into v_used from voter_tokens where election_id = p_election_id and used = true;
  select count(*) into v_votes from votes where election_id = p_election_id;
  return jsonb_build_object(
    'codes_total', v_total, 'codes_used', v_used, 'votes', v_votes
  );
end;
$$;

create or replace function admin_tally(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare v_out jsonb;
begin
  perform public.require_admin();
  select coalesce(jsonb_agg(t order by t.votes desc), '[]'::jsonb) into v_out
  from (
    select c.id as candidate_id, c.name, c.position,
      count(v.id)::bigint as votes
    from candidates c
    left join votes v on v.election_id = c.election_id
      and (v.monitor_candidate_id = c.id or v.cr_candidate_id = c.id)
    where c.election_id = p_election_id
    group by c.id, c.name, c.position
  ) t;
  return v_out;
end;
$$;

create or replace function admin_generate_codes(p_election_id uuid, p_hashes text[])
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_count int := 0;
begin
  perform public.require_admin();
  if not exists (select 1 from elections where id = p_election_id) then
    raise exception 'Election not found';
  end if;
  if coalesce(array_length(p_hashes, 1), 0) > 500 then
    raise exception 'Too many codes (max 500 per batch)';
  end if;
  insert into voter_tokens (election_id, token_hash)
  select p_election_id, h from unnest(p_hashes) as h
  on conflict (token_hash) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function admin_list_id_verifications(p_election_id uuid)
returns table (verification_id uuid, path text, created_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  perform public.require_admin();
  return query select v.id, v.path, v.created_at
    from id_verifications v
    where v.election_id = p_election_id
    order by v.created_at desc;
end;
$$;

create or replace function admin_cleanup_orphan_uploads()
returns text[]
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_paths text[];
begin
  perform public.require_admin();
  select array_agg(path) into v_paths
  from id_uploads
  where used = false and expires_at < now();
  delete from id_uploads where used = false and expires_at < now();
  return coalesce(v_paths, '{}'::text[]);
end;
$$;

-- ---------- Execute grants (deny-by-default) ----------

revoke all on function validate_token(text) from public;
grant execute on function validate_token(text) to anon;

revoke all on function request_id_upload(text) from public;
grant execute on function request_id_upload(text) to anon;

revoke all on function cast_vote(text, uuid, uuid, uuid) from public;
revoke all on function cast_vote(text, uuid, uuid, uuid) from anon;
revoke all on function cast_vote(text, uuid, uuid, uuid) from authenticated;
-- v7 hardening: legacy token-based cast_vote is obsolete (superseded by
-- cast_vote_v2) and must not be invokable via PostgREST by anyone.

revoke all on function am_i_admin() from public;
grant execute on function am_i_admin() to authenticated;

revoke all on function claim_first_admin() from public;
grant execute on function claim_first_admin() to authenticated;

revoke all on function admin_list_elections() from public;
grant execute on function admin_list_elections() to authenticated;

revoke all on function admin_create_election(text) from public;
grant execute on function admin_create_election(text) to authenticated;

revoke all on function admin_update_election(uuid, text, boolean, boolean) from public;
grant execute on function admin_update_election(uuid, text, boolean, boolean) to authenticated;

revoke all on function admin_delete_election(uuid) from public;
grant execute on function admin_delete_election(uuid) to authenticated;

revoke all on function admin_list_candidates(uuid) from public;
grant execute on function admin_list_candidates(uuid) to authenticated;

revoke all on function admin_delete_candidate(uuid) from public;
grant execute on function admin_delete_candidate(uuid) to authenticated;

revoke all on function admin_stats(uuid) from public;
grant execute on function admin_stats(uuid) to authenticated;

revoke all on function admin_tally(uuid) from public;
grant execute on function admin_tally(uuid) to authenticated;

revoke all on function admin_generate_codes(uuid, text[]) from public;
grant execute on function admin_generate_codes(uuid, text[]) to authenticated;

revoke all on function admin_list_id_verifications(uuid) from public;
grant execute on function admin_list_id_verifications(uuid) to authenticated;

revoke all on function admin_cleanup_orphan_uploads() from public;
grant execute on function admin_cleanup_orphan_uploads() to authenticated;


-- ================= MIGRATION v3 (ID upload fixes: slot-open check, cast_vote file visibility) [migration_v3.sql] =================

-- ============================================================================
-- migration_v3.sql — security patches on top of migration_v2
-- Apply AFTER migration_v2.sql on the live database.
-- Idempotent: safe to re-run.
--
-- Fix 1: storage policies queried public.id_uploads directly, but id_uploads has
--   RLS enabled with no anon policy, so the EXISTS() check always failed and every
--   ID upload was rejected (403). Now a SECURITY DEFINER helper performs the
--   slot check (returns only boolean, leaks nothing).
-- Fix 2: cast_vote accepted a vote when only an upload *slot* was requested, even
--   if the ID photo file was never uploaded. Now the file must actually exist in
--   storage before the vote is counted (highest security for elections).
-- ============================================================================

-- ---------- Fix 1: RLS-safe slot check helper ----------
create or replace function public.id_upload_slot_open(p_path text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.id_uploads u
    where u.path = p_path
      and u.used = false
      and u.expires_at > now()
  );
$$;

revoke all on function public.id_upload_slot_open(text) from public;
grant execute on function public.id_upload_slot_open(text) to anon;

drop policy if exists "voter id upload" on storage.objects;
create policy "voter id upload"
  on storage.objects for insert to anon
  with check (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

-- NOTE: file-type/size are NOT checked here. Supabase storage evaluates the
-- INSERT policy before it populates objects.metadata, so metadata-based checks
-- always fail at upload time. Type/size are enforced in cast_vote() instead,
-- which reads the stored metadata as SECURITY DEFINER.
drop policy if exists "voter id re-upload" on storage.objects;
create policy "voter id re-upload"
  on storage.objects for update to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  )
  with check (
    bucket_id = 'id-cards'
  );

-- Scoped SELECT so the storage server's bulk remove() can list the voter's own
-- pending file before deleting it. Same slot-bound scope as insert/delete.
drop policy if exists "voter id select own pending" on storage.objects;
create policy "voter id select own pending"
  on storage.objects for select to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

-- Lets a voter delete ONLY their own pending upload (open slot path, before
-- the vote is cast). Used for re-upload as remove + upload fresh, because the
-- storage server's upsert conflicts with RLS even under a permissive policy.
drop policy if exists "voter id delete own pending" on storage.objects;
create policy "voter id delete own pending"
  on storage.objects for delete to anon
  using (
    bucket_id = 'id-cards'
    and public.id_upload_slot_open(name)
  );

-- ---------- Fix 2: cast_vote must see the actual ID file ----------
create or replace function cast_vote(
  p_token_hash text,
  p_monitor_id uuid,
  p_cr_id uuid,
  p_upload_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_election_id uuid;
  v_status text;
  v_require_id boolean;
  v_path text;
  v_mime text;
  v_size bigint;
  v_identity text;
begin
  select t.election_id
    into v_election_id
  from voter_tokens t
  where t.token_hash = p_token_hash
    and t.used = false
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Invalid or already-used code');
  end if;

  select e.status, e.require_id_card
    into v_status, v_require_id
  from elections e where e.id = v_election_id;

  if v_status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'Voting is closed');
  end if;

  if v_require_id then
    if p_upload_id is null then
      return jsonb_build_object('ok', false, 'error', 'ID card upload is required for this election');
    end if;
    select u.path
      into v_path
    from id_uploads u
    where u.id = p_upload_id
      and u.token_hash = p_token_hash
      and u.used = false
      and u.expires_at > now();
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID upload missing or expired — please upload your ID again');
    end if;
    -- Highest security: a requested slot alone is not enough. The ID photo file
    -- must actually exist in storage, be an image, and respect the size limit.
    -- (Type/size are enforced here because storage RLS runs before the storage
    --  server populates objects.metadata.)
    select o.metadata ->> 'mimetype', (o.metadata ->> 'size')::bigint
      into v_mime, v_size
    from storage.objects o
    where o.bucket_id = 'id-cards'
      and o.name = v_path;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'ID photo not uploaded yet — please upload your ID card photo');
    end if;
    if v_mime is null or v_mime not like 'image/%' then
      return jsonb_build_object('ok', false, 'error', 'ID photo must be an image file (JPG/PNG/WebP)');
    end if;
    if v_size is null or v_size > 6291456 then
      return jsonb_build_object('ok', false, 'error', 'ID photo is too large (max 6 MB)');
    end if;
    update id_uploads u
      set used = true
      where u.id = p_upload_id;
  end if;

  if p_monitor_id is not null and not exists (
    select 1 from candidates
    where id = p_monitor_id
      and election_id = v_election_id
      and position = 'monitor'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid Monitor candidate');
  end if;

  if p_cr_id is not null and not exists (
    select 1 from candidates
    where id = p_cr_id
      and election_id = v_election_id
      and position = 'cr'
  ) then
    return jsonb_build_object('ok', false, 'error', 'Invalid CR candidate');
  end if;

  if p_monitor_id is null and p_cr_id is null then
    return jsonb_build_object('ok', false, 'error', 'Select at least one candidate');
  end if;

  loop
    v_identity := upper(encode(gen_random_bytes(4), 'hex'));
    v_identity := substring(v_identity, 1, 4) || '-' || substring(v_identity, 5, 4);
    exit when not exists (select 1 from votes where voter_identity = v_identity);
  end loop;

  insert into votes (election_id, token_hash, monitor_candidate_id, cr_candidate_id, voter_identity)
  values (v_election_id, p_token_hash, p_monitor_id, p_cr_id, v_identity);

  if v_require_id then
    insert into id_verifications (election_id, token_hash, path)
    values (v_election_id, p_token_hash, v_path);
  end if;

  update voter_tokens
  set used = true, used_at = now()
  where token_hash = p_token_hash;

  return jsonb_build_object('ok', true, 'voter_identity', v_identity);

exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'This code has already voted');
end;
$$;


-- ================= MIGRATION v4 (security hardening: v2 slots, opaque paths, admin role RPCs, election_settings) [migration_v4.sql] =================

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
  phone text,
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
  require_phone boolean not null default false,
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
drop function if exists public.register_voter(uuid, text, text, text);

create or replace function public.register_voter(
  p_election_id uuid,
  p_name text default null,
  p_class text default null,
  p_enrollment_id text default null,
  p_phone text default null
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
  v_ready boolean := false;
  v_digits text;
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

  -- normalize phone to digits; validate format whenever a value is given
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if v_digits <> '' and length(v_digits) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'Enter a valid 10-digit mobile number');
  end if;
  if v_s.require_phone and v_digits = '' then
    return jsonb_build_object('ok', false, 'error', 'Mobile number is required');
  end if;

  -- server-authoritative ID state for this voter
  v_ready := public.id_upload_ready_v2(p_election_id, auth.uid());

  -- auto-verify only when there is no manual review AND any required ID
  -- is already uploaded; otherwise the registration stays pending.
  if not v_s.manual_review and v_ready then
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
    (election_id, user_id, name, class, enrollment_id, phone, status)
  values
    (p_election_id, auth.uid(),
     nullif(trim(coalesce(p_name, '')), ''),
     nullif(trim(coalesce(p_class, '')), ''),
     nullif(trim(coalesce(p_enrollment_id, '')), ''),
     nullif(v_digits, ''),
     v_status)
  on conflict (election_id, user_id) do update set
    name = excluded.name,
    class = excluded.class,
    enrollment_id = excluded.enrollment_id,
    phone = excluded.phone,
    status = case
      when public.voter_registrations.status = 'rejected'
        then case when not v_s.manual_review and v_ready then 'verified' else 'pending' end
      when public.voter_registrations.status = 'pending'
       and not v_s.manual_review and v_ready then 'verified'
      else public.voter_registrations.status
    end
  where public.voter_registrations.voted_at is null
  returning id into v_reg_id;

  -- final authoritative status + id state
  select r.status into v_status
    from public.voter_registrations r where r.id = v_reg_id;

  return jsonb_build_object(
    'ok', true,
    'status', v_status,
    'registration_id', v_reg_id,
    'id_ready', v_ready
  );
end;
$$;
revoke all on function public.register_voter(uuid, text, text, text, text) from public;
grant execute on function public.register_voter(uuid, text, text, text, text) to authenticated;

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

drop function if exists public.admin_update_settings(uuid, boolean, boolean, boolean, boolean, boolean);

create or replace function public.admin_update_settings(
  p_election_id uuid,
  p_require_name boolean default null,
  p_require_class boolean default null,
  p_require_enrollment_id boolean default null,
  p_require_id_upload boolean default null,
  p_manual_review boolean default null,
  p_require_phone boolean default null
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
    manual_review = coalesce(p_manual_review, manual_review),
    require_phone = coalesce(p_require_phone, require_phone)
  where election_id = p_election_id;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.admin_update_settings(uuid, boolean, boolean, boolean, boolean, boolean, boolean) from public;
grant execute on function public.admin_update_settings(uuid, boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

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
      'phone', r.phone,
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


-- ================= MIGRATION v5 (server-side ID enforcement + id_ready, vote idempotency, safe metadata casts) [migration_v5.sql] =================

-- ============================================================================
-- migration_v5.sql — registration-stage ID enforcement + vote idempotency
-- Apply AFTER migration_v4.sql on the live database.
-- Idempotent: safe to re-run (uses IF NOT EXISTS / CREATE OR REPLACE).
--
-- What changes:
--   1. public.id_upload_ready_v2(election, user) -> boolean
--      Server-authoritative ID state: true when ID upload is not required,
--      else true only when a live (unused, unexpired) upload slot is backed
--      by a real image object (<= 6 MB) in the id-cards bucket.
--   2. register_voter: no auto-verify when an ID is required but missing;
--      response now includes id_ready.
--   3. NEW confirm_id_upload_v2: voter calls after the storage upload
--      succeeds; validates the object server-side and flips a pending
--      auto-review registration to verified.
--   4. admin_verify_registration: approval is REJECTED when an ID is
--      required but no valid upload exists (server-side, cannot be bypassed).
--   5. get_ballot / admin_list_registrations: registration rows now carry
--      id_ready so the UI never guesses from local state.
--   6. cast_vote_v2 gains p_idempotency_key: replaying the same key after a
--      lost response returns the ORIGINAL receipt; a different vote attempt
--      is still blocked. New votes.idempotency_key column.
-- ============================================================================

-- ---------- 1. votes.idempotency_key ----------
alter table public.votes
  add column if not exists idempotency_key text;

-- ---------- 2. server-authoritative ID readiness ----------
create or replace function public.id_upload_ready_v2(p_election_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_required boolean;
  v_ok boolean;
begin
  perform public.ensure_election_settings(p_election_id);
  select s.require_id_upload into v_required
    from public.election_settings s
   where s.election_id = p_election_id;
  if not coalesce(v_required, false) then
    return true;
  end if;
  if p_user_id is null then
    return false;
  end if;
  select exists (
    select 1
      from public.id_uploads u
      join storage.objects o
        on o.bucket_id = 'id-cards'
       and o.name = u.path
     where u.election_id = p_election_id
       and u.user_id = p_user_id
       and u.used = false
       and u.expires_at > now()
       and o.metadata ->> 'mimetype' like 'image/%'
       and (o.metadata ->> 'size') ~ '^[0-9]{1,7}$'
       and (o.metadata ->> 'size')::bigint between 1 and 6291456
  ) into v_ok;
  return coalesce(v_ok, false);
end;
$$;
revoke all on function public.id_upload_ready_v2(uuid, uuid) from public;
grant execute on function public.id_upload_ready_v2(uuid, uuid) to authenticated;

-- ---------- 3. register_voter: gate auto-verify on ID readiness ----------
drop function if exists public.register_voter(uuid, text, text, text);

create or replace function public.register_voter(
  p_election_id uuid,
  p_name text default null,
  p_class text default null,
  p_enrollment_id text default null,
  p_phone text default null
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
  v_ready boolean := false;
  v_digits text;
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

  -- normalize phone to digits; validate format whenever a value is given
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if v_digits <> '' and length(v_digits) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'Enter a valid 10-digit mobile number');
  end if;
  if v_s.require_phone and v_digits = '' then
    return jsonb_build_object('ok', false, 'error', 'Mobile number is required');
  end if;

  -- server-authoritative ID state for this voter
  v_ready := public.id_upload_ready_v2(p_election_id, auth.uid());

  -- auto-verify only when there is no manual review AND any required ID
  -- is already uploaded; otherwise the registration stays pending.
  if not v_s.manual_review and v_ready then
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
    (election_id, user_id, name, class, enrollment_id, phone, status)
  values
    (p_election_id, auth.uid(),
     nullif(trim(coalesce(p_name, '')), ''),
     nullif(trim(coalesce(p_class, '')), ''),
     nullif(trim(coalesce(p_enrollment_id, '')), ''),
     nullif(v_digits, ''),
     v_status)
  on conflict (election_id, user_id) do update set
    name = excluded.name,
    class = excluded.class,
    enrollment_id = excluded.enrollment_id,
    phone = excluded.phone,
    status = case
      when public.voter_registrations.status = 'rejected'
        then case when not v_s.manual_review and v_ready then 'verified' else 'pending' end
      when public.voter_registrations.status = 'pending'
       and not v_s.manual_review and v_ready then 'verified'
      else public.voter_registrations.status
    end
  where public.voter_registrations.voted_at is null
  returning id into v_reg_id;

  -- final authoritative status + id state
  select r.status into v_status
    from public.voter_registrations r where r.id = v_reg_id;

  return jsonb_build_object(
    'ok', true,
    'status', v_status,
    'registration_id', v_reg_id,
    'id_ready', v_ready
  );
end;
$$;
revoke all on function public.register_voter(uuid, text, text, text, text) from public;
grant execute on function public.register_voter(uuid, text, text, text, text) to authenticated;

-- ---------- 4. confirm_id_upload_v2 ----------
-- Called by the voter right after the storage upload succeeds. Validates
-- the object server-side; flips a pending auto-review registration to
-- verified. Manual-review registrations stay pending for the admin.
create or replace function public.confirm_id_upload_v2(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg public.voter_registrations%rowtype;
  v_s public.election_settings%rowtype;
  v_ready boolean;
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

  v_ready := public.id_upload_ready_v2(p_election_id, auth.uid());
  if not v_ready then
    return jsonb_build_object(
      'ok', false,
      'error', 'ID photo not found on the server — please upload again',
      'id_ready', false
    );
  end if;

  perform public.ensure_election_settings(p_election_id);
  select * into v_s from public.election_settings where election_id = p_election_id;

  if v_reg.status = 'pending' and not v_s.manual_review then
    update public.voter_registrations
       set status = 'verified'
     where id = v_reg.id and status = 'pending';
    v_reg.status := 'verified';
  end if;

  return jsonb_build_object('ok', true, 'id_ready', true, 'status', v_reg.status);
end;
$$;
revoke all on function public.confirm_id_upload_v2(uuid) from public;
grant execute on function public.confirm_id_upload_v2(uuid) to authenticated;

-- ---------- 5. admin_verify_registration: server-side ID gate ----------
create or replace function public.admin_verify_registration(
  p_registration_id uuid,
  p_approved boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg public.voter_registrations%rowtype;
begin
  perform public.require_admin();
  select * into v_reg from public.voter_registrations where id = p_registration_id;
  if v_reg.id is null then
    return jsonb_build_object('ok', false, 'error', 'Registration not found');
  end if;
  if v_reg.voted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'Voter has already voted');
  end if;
  if p_approved then
    -- id_upload_ready_v2 returns true when no ID is required, so a false
    -- here always means "required but missing/invalid".
    if not public.id_upload_ready_v2(v_reg.election_id, v_reg.user_id) then
      return jsonb_build_object(
        'ok', false,
        'error', 'ID photo required — voter ne abhi tak valid ID upload nahi ki'
      );
    end if;
  end if;
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

-- ---------- 6. get_ballot: expose id_ready on the registration ----------
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
        'name', r.name, 'class', r.class, 'enrollment_id', r.enrollment_id,
        'id_ready', public.id_upload_ready_v2(p_election_id, auth.uid())
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

-- ---------- 7. admin_list_registrations: expose id_ready per row ----------
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
      'phone', r.phone,
      'status', r.status,
      'voted', r.voted_at is not null,
      'created_at', r.created_at,
      'id_ready', public.id_upload_ready_v2(r.election_id, r.user_id),
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

-- ---------- 8. cast_vote_v2: idempotency key ----------
-- A replay with the SAME key returns the original receipt instead of an
-- "already voted" error (safe retry after a lost response). Any different
-- attempt to vote again is still blocked.
drop function if exists public.cast_vote_v2(uuid, uuid, uuid);

create or replace function public.cast_vote_v2(
  p_election_id uuid,
  p_monitor_id uuid default null,
  p_cr_id uuid default null,
  p_idempotency_key text default null
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
  v_key text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Please sign in first');
  end if;
  v_key := nullif(trim(coalesce(p_idempotency_key, '')), '');

  select * into v_reg from public.voter_registrations
   where election_id = p_election_id and user_id = auth.uid()
   for update;
  if v_reg.id is null then
    return jsonb_build_object('ok', false, 'error', 'Please complete registration first');
  end if;
  if v_reg.voted_at is not null then
    -- idempotent replay: same key -> original receipt, no new vote
    if v_key is not null then
      select v.voter_identity into v_identity
        from public.votes v
       where v.registration_id = v_reg.id
         and v.idempotency_key = v_key;
      if found then
        return jsonb_build_object('ok', true, 'voter_identity', v_identity, 'replay', true);
      end if;
    end if;
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
    select o.metadata ->> 'mimetype',
           case when (o.metadata ->> 'size') ~ '^[0-9]+$' then (o.metadata ->> 'size')::bigint end
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
    (election_id, registration_id, monitor_candidate_id, cr_candidate_id, voter_identity, idempotency_key)
  values
    (p_election_id, v_reg.id, p_monitor_id, p_cr_id, v_identity, v_key);

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
revoke all on function public.cast_vote_v2(uuid, uuid, uuid, text) from public;
grant execute on function public.cast_vote_v2(uuid, uuid, uuid, text) to authenticated;

-- ---------- 6. admin_vote_audit: who voted for whom (read-only) ----------
-- Returns every vote in the election joined to the voter's identity and
-- their chosen candidates, plus a duplicate-phone fraud report.
-- Read-only: this function never writes to votes or any other table.
create or replace function public.admin_vote_audit(p_election_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
  v_dups jsonb;
begin
  perform public.require_admin();

  select coalesce(jsonb_agg(jsonb_build_object(
      'vote_id', v.id,
      'voted_at', v.created_at,
      'receipt', v.voter_identity,
      'name', r.name,
      'email', u.email,
      'class', r.class,
      'enrollment_id', r.enrollment_id,
      'phone', r.phone,
      'monitor', mc.name,
      'cr', cc.name
    ) order by v.created_at desc), '[]'::jsonb)
    into v_rows
    from public.votes v
    left join public.voter_registrations r on r.id = v.registration_id
    left join auth.users u on u.id = r.user_id
    left join public.candidates mc on mc.id = v.monitor_candidate_id
    left join public.candidates cc on cc.id = v.cr_candidate_id
   where v.election_id = p_election_id;

  -- fraud signal: the same phone number on more than one registration
  select coalesce(jsonb_agg(jsonb_build_object(
      'phone', d.phone,
      'count', d.cnt,
      'voters', d.voters
    )), '[]'::jsonb)
    into v_dups
    from (
      select r.phone as phone,
             count(*) as cnt,
             jsonb_agg(jsonb_build_object(
               'name', r.name,
               'email', u.email,
               'voted', r.voted_at is not null
             ) order by r.created_at) as voters
        from public.voter_registrations r
        join auth.users u on u.id = r.user_id
       where r.election_id = p_election_id
         and nullif(r.phone, '') is not null
       group by r.phone
      having count(*) > 1
    ) d;

  return jsonb_build_object(
    'ok', true,
    'votes', v_rows,
    'total', jsonb_array_length(v_rows),
    'duplicate_phones', v_dups
  );
end;
$$;
revoke all on function public.admin_vote_audit(uuid) from public;
grant execute on function public.admin_vote_audit(uuid) to authenticated;
-- ================= MIGRATION v7 (harden obsolete token-voting path) =================
-- The app now votes exclusively through cast_vote_v2 (auth + verified
-- registration). The legacy token-based cast_vote(text, uuid, uuid, uuid)
-- is no longer called by any client. An admin could previously mint voting
-- codes via admin_generate_codes and then cast votes with them through the
-- legacy path, which bypasses the registration/approval chain.
--
-- This migration revokes every grant on the legacy function so it cannot be
-- invoked through PostgREST by anon OR authenticated callers. The function
-- body is kept (not dropped) so the change is trivially reversible.
-- Idempotent: safe to run more than once.
-- ==============================================================================

-- legacy 4-arg cast_vote: token-based voting (obsolete, superseded by cast_vote_v2)
revoke all on function public.cast_vote(text, uuid, uuid, uuid) from public;
revoke all on function public.cast_vote(text, uuid, uuid, uuid) from anon;
revoke all on function public.cast_vote(text, uuid, uuid, uuid) from authenticated;

-- belt & braces: also revoke the older 3-arg / other legacy signatures if present
do $$
begin
  if exists (select 1 from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'cast_vote'
               and pg_get_function_identity_arguments(p.oid) = 'text, uuid, uuid') then
    revoke all on function public.cast_vote(text, uuid, uuid) from public;
    revoke all on function public.cast_vote(text, uuid, uuid) from anon;
    revoke all on function public.cast_vote(text, uuid, uuid) from authenticated;
  end if;
end $$;

-- admin_generate_codes stays admin-gated (require_admin() in body) and is kept
-- for compatibility, but with legacy cast_vote revoked its codes can no longer
-- be turned into votes through any API.
