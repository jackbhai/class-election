-- ============================================================================
-- migration_v6.sql — voter phone identity + admin vote audit
-- ============================================================================
-- 1. voter_registrations gains an optional phone (mobile number) column.
-- 2. election_settings gains require_phone (admin toggle).
-- 3. register_voter() accepts + validates p_phone (10 digits when provided;
--    mandatory when require_phone is on).
-- 4. admin_update_settings() accepts p_require_phone.
-- 5. admin_list_registrations() includes phone.
-- 6. NEW admin_vote_audit(): read-only, admin-gated view of who voted for
--    whom + duplicate-phone fraud flags.
-- Security notes (unchanged):
--  * votes has RLS enabled with ZERO policies: nobody (not even admin) can
--    read/insert/update/delete votes directly. Only cast_vote_v2() writes,
--    bound to the caller's own verified registration.
--  * admin_vote_audit() is read-only and gated by require_admin().
-- ============================================================================

-- ---------- 1. phone column ----------
alter table public.voter_registrations
  add column if not exists phone text;

-- ---------- 2. require_phone toggle ----------
alter table public.election_settings
  add column if not exists require_phone boolean not null default false;

-- ---------- 3. register_voter gains p_phone ----------
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

-- ---------- 4. admin_update_settings gains p_require_phone ----------
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

-- ---------- 5. admin_list_registrations includes phone ----------
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
