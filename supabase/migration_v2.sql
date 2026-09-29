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

create or replace function claim_first_admin()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
  v_email text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'Not signed in');
  end if;
  select count(*) into v_count from public.profiles where is_admin = true;
  if v_count > 0 then
    return jsonb_build_object('ok', false, 'error', 'An admin already exists');
  end if;
  select email into v_email from auth.users where id = auth.uid();
  insert into public.profiles (id, email, is_admin)
  values (auth.uid(), v_email, true)
  on conflict (id) do update set is_admin = true, email = excluded.email;
  return jsonb_build_object('ok', true);
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
grant execute on function cast_vote(text, uuid, uuid, uuid) to anon;

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
