REVOKE EXECUTE ON FUNCTION public.finish_combat_battle(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.apply_simulated_combat_round(uuid,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_next_combat_round(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.simulate_combat_round_v3(uuid,integer) FROM PUBLIC;