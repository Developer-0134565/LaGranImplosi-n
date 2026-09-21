-- ============================================================================
-- RETIRE public.research_action_candidates AS A CLIENT CONTRACT (forward-only)
-- ----------------------------------------------------------------------------
-- FINDING (LIVE audit 2026-09-21): the view is the documented "intended UI
-- availability layer", but it is UNUSABLE by every client role. It is
-- security_invoker and its calculate_research_time(...) call reads
-- public.universes, which has no table GRANT for anon/authenticated:
--   -> ERROR 42501 permission denied for table universes
-- It is also prerequisite-blind (it never consults research_prerequisites), so
-- even a repaired copy could not serve as an availability contract.
--
-- DECISION: can_start_research(player_id, planet_id, research_id) is the SINGLE
-- authoritative client availability surface. It already returns allowed,
-- reason_code, costs, available resources, research_seconds, item_bonus_percent,
-- finishes_at_estimate, prerequisites_met, prerequisites, queue_available and
-- active_job. The view is therefore retired AS A CLIENT CONTRACT.
--
-- This does NOT drop the view. It is an internal dependency of the
-- decision-support view family:
--   research_action_candidates -> action_candidates -> executable_action_candidates
--                                                  -> executable_optimization_candidates
-- so it is preserved for that family and for admin/service_role use.
--
-- No GRANT on universes is added (that would rescue a redundant,
-- prerequisite-blind view and widen client access). No RLS policy, function or
-- table is modified.
-- ============================================================================

revoke all on public.research_action_candidates from anon;
revoke all on public.research_action_candidates from authenticated;

do $gate$
begin
  if exists (
    select 1 from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'research_action_candidates'
      and grantee in ('anon', 'authenticated')
  ) then
    raise exception 'RETIRE_POSTCONDITION_FAILED: research_action_candidates still carries client grants';
  end if;

  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'research_action_candidates' and c.relkind = 'v'
  ) then
    raise exception 'RETIRE_POSTCONDITION_FAILED: research_action_candidates no longer exists';
  end if;
end
$gate$;
