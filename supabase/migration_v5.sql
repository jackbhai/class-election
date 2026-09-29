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
  v_ready boolean := false;
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
revoke all on function public.register_voter(uuid, text, text, text) from public;
grant execute on function public.register_voter(uuid, text, text, text) to authenticated;

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
