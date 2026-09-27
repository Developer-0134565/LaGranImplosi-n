-- ============================================================================================
-- LGI - H5: the two wreck-field helpers are internal, not client contracts
-- ============================================================================================
-- Demonstrated by the integral Supabase<->frontend audit (2026-09-26): as a FOREIGN authenticated actor it was
-- possible to read another player's Space Dock level through wreck_field_space_dock_level (a SECURITY DEFINER
-- helper over planet_buildings, which is otherwise RLS-hidden), and both helpers were executable by anon and
-- authenticated.
--
-- Evidence collected before this revoke:
--   * wreck_field_space_dock_level / wreck_field_recover_percent are called only by wreck-field internals
--     (create_or_extend_wreck_field, start_wreck_field_repairs) and by service_role/DIAGNOSTIC callers;
--   * the frontend has ZERO references to wreck field, Space Dock or these helpers;
--   * service_role keeps EXECUTE, so the worker and the (future) UI contract path are unaffected.
-- ============================================================================================

revoke all on function public.wreck_field_space_dock_level(uuid) from public, anon, authenticated;
revoke all on function public.wreck_field_recover_percent(integer) from public, anon, authenticated;
grant execute on function public.wreck_field_space_dock_level(uuid) to service_role;
grant execute on function public.wreck_field_recover_percent(integer) to service_role;