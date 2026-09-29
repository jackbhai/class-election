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
