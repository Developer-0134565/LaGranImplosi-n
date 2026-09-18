REVOKE EXECUTE ON FUNCTION public.update_planet_resources(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.complete_research(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.apply_attack_loot(uuid) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_attack_arrival(uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public.update_planet_resources(uuid) IS 'Legacy resource updater retained for internal compatibility; authoritative callers must use process_planet_tick/update_planet_resources_until.';
COMMENT ON FUNCTION public.complete_research(uuid) IS 'Internal completion entrypoint; authoritative processing is performed by process_research_queue/process_planet_tick.';
COMMENT ON FUNCTION public.load_fleet_cargo(uuid, numeric, numeric, numeric) IS 'Internal fleet cargo mutation; must not be exposed to client roles.';
COMMENT ON FUNCTION public.apply_attack_loot(uuid) IS 'Internal combat loot mutation; invoked by attack resolution only.';
