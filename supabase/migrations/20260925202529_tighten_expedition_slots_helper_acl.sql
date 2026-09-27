-- ACL hygiene for a function modified by the expedition block: get_player_expedition_slots is an INTERNAL
-- helper (consumed by start_fleet / start_fleet_mixed, both SECURITY DEFINER). It previously carried the
-- default PUBLIC/anon/authenticated EXECUTE grant. Clients now use the owner-scoped read contract
-- `get_player_expedition_slot_status()`, so the helper is closed to client roles.
revoke all on function public.get_player_expedition_slots(uuid) from public;
revoke all on function public.get_player_expedition_slots(uuid) from anon;
revoke all on function public.get_player_expedition_slots(uuid) from authenticated;
grant execute on function public.get_player_expedition_slots(uuid) to service_role;
