-- FLEET ENGINE — companion ACL closure to `20260925211615_tighten_fleet_calculation_helper_acl`.
--
-- The transversal audit found a THIRD internal calculation helper from the same family that still carried the
-- default PUBLIC EXECUTE grant (verified LIVE 2026-09-25 with a per-entry ACL probe, not a LIKE match):
--
--   * calculate_fleet_distance_to_coordinates(uuid,integer,integer,integer) -- §7 distance model for
--     coordinate-only targets (colonisation, recycling, expeditions). SECURITY INVOKER; PUBLIC EXECUTE.
--
-- This statement was applied as its own forward-only migration instead of being appended to
-- `20260925211615` so that the repository file and the LIVE ledger stay one-to-one (appending to an already
-- applied migration would have created version drift — see the provenance gate).
--
-- Evidence that closing it is safe (LIVE, 2026-09-25): the only consumers are start_fleet, start_fleet_mixed
-- and start_colonize_fleet — all SECURITY DEFINER and owned by `postgres`, so they keep EXECUTE — and the
-- frontend (src/**) never calls it. No formula, signature or gameplay value changes.

revoke all on function public.calculate_fleet_distance_to_coordinates(uuid, integer, integer, integer) from public;
revoke all on function public.calculate_fleet_distance_to_coordinates(uuid, integer, integer, integer) from anon;
revoke all on function public.calculate_fleet_distance_to_coordinates(uuid, integer, integer, integer) from authenticated;
grant execute on function public.calculate_fleet_distance_to_coordinates(uuid, integer, integer, integer) to service_role;
