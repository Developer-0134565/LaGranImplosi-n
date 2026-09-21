-- ============================================================================
-- COMBAT ENGINE PHASE 1 — CB-05 REPAIR (combat-scoped ACL narrowing)
-- ----------------------------------------------------------------------------
-- Phase 0 recorded that a set of combat-internal helpers kept EXECUTE for
-- PUBLIC / anon / authenticated. Every one of them is either an internal step of
-- the authoritative pipeline or a derived reader of tables that RLS already
-- denies to client roles, so the client-facing grant is unused surface.
--
-- Proven before changing anything (see README_COMBAT_ENGINE section 15):
--   1. no client caller exists: the frontend's only RPC calls are
--      sync_current_planet_resources, can_start_building, can_start_research,
--      can_build_ship, can_build_defense, start_fleet_mixed, start_fleet and
--      get_universe_evolution_monitor_public (src/);
--   2. the production callers are unaffected: every internal caller chain runs
--      under SECURITY DEFINER functions owned by postgres, and all functions
--      touched here are owned by postgres, which always keeps its privileges;
--   3. no client contract depends on them: all combat tables carry an
--      ALL-command deny_direct_api_access policy for anon/authenticated, so a
--      client call could never read a single row;
--   4. the change is strictly combat-scoped: only combat* functions are touched;
--   5. the result is verified LIVE (has_function_privilege before/after) and by
--      re-running the production-path combat fixtures.
--
-- service_role keeps EXECUTE on every function listed below, so the
-- pg_cron fleet worker, resolve_attack_arrival and the expedition creators keep
-- working unchanged. Only PUBLIC / anon / authenticated are narrowed.
-- ============================================================================

revoke execute on function public.calculate_shield_bounce(numeric, numeric) from public, anon, authenticated;
revoke execute on function public.calculate_combat_damage(numeric, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.calculate_combat_ship_losses(uuid) from public, anon, authenticated;
revoke execute on function public.calculate_combat_defense_losses(uuid) from public, anon, authenticated;
revoke execute on function public.calculate_combat_ship_debris(uuid) from public, anon, authenticated;
revoke execute on function public.calculate_combat_defense_debris(uuid) from public, anon, authenticated;
revoke execute on function public.calculate_combat_total_debris(uuid) from public, anon, authenticated;
revoke execute on function public.combat_hull_from_integrity(numeric) from public, anon, authenticated;
revoke execute on function public.get_combat_round_snapshot(uuid, integer) from public, anon, authenticated;
revoke execute on function public.get_combat_unit_snapshot(uuid) from public, anon, authenticated;
revoke execute on function public.expand_all_rapidfire_v2(uuid, integer) from public, anon, authenticated;
revoke execute on function public.finish_combat_round_v1(uuid, integer) from public, anon, authenticated;
