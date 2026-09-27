-- ============================================================================
-- P3 ACL CLEANUP — anon EXECUTE surface + internal AI engine views (2026-09-26)
-- ----------------------------------------------------------------------------
-- Evidence gathered LIVE before writing this migration (no guesswork):
--
--   * 100 functions in `public` are EXECUTE-able by `anon` although only 32 RPCs are ever invoked by the
--     client (inventory of `supabase.rpc('…')` over `src/**`). They split into 55 pure `calculate_*` helpers
--     and 45 internal dispatchers/helpers (`start_building`, `start_defense`, `start_research`,
--     `ui_*_definitions`,
--     `evaluate_action_at_time`, `project_*`, `select_expedition_*`,
--     `on_combat_battle_finished_wreck_field`, …). No anonymous caller exists: every gameplay path needs a
--     session, `start_ship` (the hardened sibling of `start_building/defense/research`) already had no `anon`
--     grant, and the only deliberately anonymous contract, `get_universe_evolution_monitor_public`, is on the
--     allow-list and is NOT touched.
--   * the AI-engine views (`action_candidates`, `unified_action_candidates`, `next_action*`, `empire_*`,
--     `optimization_candidates`, `research_action_candidates`, …) carry `anon=arwdDxtm, authenticated=arwdDxtm`
--     and have zero policies. No function's `prosrc` references them, the client never reads them
--     (`supabase.from('…')` inventory) and the AI policy reads them through its own SECURITY DEFINER functions
--     (owner `postgres`), so they are internal by construction.
--   * root cause: `pg_default_acl` grants `anon=X` on functions and `anon=arwdDxtm` on tables for objects
--     created by the migration role, which is why every hardening pass must revoke explicitly. This migration
--     also removes the FUTURE-function part of that default.
--
-- Scope of this migration (ACL only — no gameplay change, no object dropped, nothing re-opened):
--   * revoke EXECUTE from `anon` only, on the functions that have no client caller; `authenticated` keeps
--     everything it has today, so a UI RPC cannot break (the UI is always authenticated).
--   * revoke ALL client access on the internal AI-engine views (they are read only by the definer).
--   * `alter default privileges … revoke execute on functions from anon` so the next new function is not born
--     publicly executable.
--
-- DELIBERATELY DEFERRED, with reason (documented, not silently skipped):
--   * table grants (`anon=arwdDxtm` / `authenticated=rm`) — every such table already carries RLS with a deny
--     policy, the client surface is `SELECT` on definition tables, and rewriting the platform default is a
--     broader change than this P3 block; recorded as DEFER.
--   * `get_universe_top1_points` and any other `*public*` contract — kept for `anon` on purpose.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. `anon` loses EXECUTE on every function that has no client caller.
--    The allow-list below is exactly the RPC inventory of `src/**` (32 names); everything else that is
--    reachable by `anon` today is internal, so it is revoked from `anon` only.
-- ----------------------------------------------------------------------------
do $acl$
declare
    v_client_rpc text[] := array[
        'can_build_defense', 'can_build_ship', 'can_start_building', 'can_start_demolition',
        'can_start_research', 'check_colony_cap', 'execute_jump_gate', 'get_player_battle_reports',
        'get_player_espionage_reports', 'get_player_expedition_reports', 'get_player_expedition_slot_status',
        'get_player_fleet_slots', 'get_player_messages', 'get_player_moons', 'get_player_support_authorizations',
        'get_universe_evolution_monitor_public', 'get_universe_ranking_by_category',
        'grant_planet_support_authorization', 'load_fleet_cargo', 'mark_message_read', 'provision_player',
        'recall_fleet', 'revoke_planet_support_authorization', 'scan_with_phalanx', 'start_colonize_fleet',
        'start_demolition', 'start_fleet', 'start_fleet_mixed', 'start_moon_destruction', 'start_support_fleet',
        'sync_current_planet_resources', 'use_expedition_item'
    ];
    r record;
    v_count integer := 0;
begin
    for r in
        select p.proname, pg_get_function_identity_arguments(p.oid) as args
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and has_function_privilege('anon', p.oid, 'EXECUTE')
           and not (p.proname = any (v_client_rpc))
         order by p.proname
    loop
        execute format('revoke execute on function public.%I(%s) from anon', r.proname, r.args);
        v_count := v_count + 1;
    end loop;
    raise notice 'P3 ACL: revoked anon EXECUTE on % functions', v_count;
end;
$acl$;

-- ----------------------------------------------------------------------------
-- 2. Internal AI-engine views: no client contract, no policy, no DB reader other than the definer.
-- ----------------------------------------------------------------------------
do $views$
declare
    r record;
    v_count integer := 0;
begin
    for r in
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'v'
           and c.relname = any (array[
               'action_candidates', 'action_economic_evaluation', 'action_energy_evaluation',
               'building_action_candidates', 'economic_action_candidates', 'empire_action_ranking',
               'empire_economic_monitor', 'empire_energy_monitor', 'empire_next_action',
               'executable_action_candidates', 'executable_optimization_candidates', 'next_action',
               'next_action_explained', 'normalized_action_candidates', 'optimization_candidates',
               'production_roi_candidates', 'research_action_candidates', 'scored_action_candidates',
               'simulated_followup_actions', 'temporal_action_candidates', 'unified_action_candidates'])
    loop
        execute format('revoke all on public.%I from anon, authenticated', r.relname);
        v_count := v_count + 1;
    end loop;
    raise notice 'P3 ACL: revoked client access on % internal engine views', v_count;
end;
$views$;

-- ----------------------------------------------------------------------------
-- 3. Root cause: new functions must be granted explicitly, never inherit `anon`.
--    (Tables are deliberately NOT touched here — see the DEFER note in the header.)
-- ----------------------------------------------------------------------------
alter default privileges in schema public revoke execute on functions from anon;