-- FLEET ENGINE — ACL hygiene for the two canonical calculation helpers that still carried the default
-- PUBLIC/anon/authenticated EXECUTE grant (finding of the 2026-09-25 transversal Fleet Engine audit,
-- recorded in docs/systems/README_FLEET_ENGINE.md §27).
--
-- NOTE: the audit found a THIRD helper of the same family, `calculate_fleet_distance_to_coordinates`.
-- It is closed by its own forward-only migration `20260925211804_tighten_fleet_distance_helper_acl`
-- so that this file stays one-to-one with its LIVE ledger entry.
--
-- Targets (both are INTERNAL helpers, never client contracts):
--   * calculate_fleet_distance(uuid,uuid)            -- §7 distance model. SECURITY INVOKER, reads `planets`.
--   * calculate_fleet_travel_time(numeric×4)         -- §5/§23.3(8) the single travel-time formula.
--
-- Evidence that closing them is safe (LIVE, 2026-09-25):
--   * the only consumers of calculate_fleet_distance are start_fleet, start_fleet_mixed and
--     start_support_fleet — all SECURITY DEFINER and owned by `postgres`, so they keep EXECUTE;
--   * the only consumers of calculate_fleet_travel_time are the same dispatchers plus
--     calculate_player_fleet_fuel_for_distance (also SECURITY DEFINER, owned by `postgres`);
--   * the frontend (src/**) contains no call to either helper — the generated types are the only
--     occurrence — so no client depends on the grant;
--   * no gameplay value, formula, ordering or signature changes here. Pure grant hygiene, the same
--     treatment already applied to calculate_mission_fleet_speed_multiplier (20260919095009) and to the
--     expedition slots helper (20260925202529).
--
-- This does NOT touch the deliberate PUBLIC grant on the informational snapshot `calculate_universe_rates`
-- (§15.2 item 3 is a pending product decision about the meaning of its fleet/expedition columns).

revoke all on function public.calculate_fleet_distance(uuid, uuid) from public;
revoke all on function public.calculate_fleet_distance(uuid, uuid) from anon;
revoke all on function public.calculate_fleet_distance(uuid, uuid) from authenticated;
grant execute on function public.calculate_fleet_distance(uuid, uuid) to service_role;

revoke all on function public.calculate_fleet_travel_time(numeric, numeric, numeric, numeric) from public;
revoke all on function public.calculate_fleet_travel_time(numeric, numeric, numeric, numeric) from anon;
revoke all on function public.calculate_fleet_travel_time(numeric, numeric, numeric, numeric) from authenticated;
grant execute on function public.calculate_fleet_travel_time(numeric, numeric, numeric, numeric) to service_role;
