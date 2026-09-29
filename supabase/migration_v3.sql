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
