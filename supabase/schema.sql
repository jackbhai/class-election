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
grant execute on function cast_vote(text, uuid, uuid, uuid) to anon;

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

revoke all on function admin_add_candidate(uuid, text, text, text) from public;
grant execute on function admin_add_candidate(uuid, text, text, text) to authenticated;

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
