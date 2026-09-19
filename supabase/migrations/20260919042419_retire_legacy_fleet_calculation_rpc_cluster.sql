-- Retire the dead fleet movement calculation RPC cluster.
-- Precondition verified 2026-09-19:
-- * no pg_depend consumers;
-- * no remaining public function definitions reference these helpers;
-- * frontend audit found no consumers;
-- * calculate_fleet_travel_time remains canonical and is preserved;
-- * calculate_universe_rates remains separate and is not changed.

revoke execute on function public.calculate_expedition_time(uuid, text, bigint) from anon, authenticated;
revoke execute on function public.calculate_fleet_time(uuid, uuid, text, bigint) from anon, authenticated;
revoke execute on function public.calculate_fleet_fuel(uuid, uuid, text, bigint) from anon, authenticated;
revoke execute on function public.calculate_fleet_fuel_mixed(uuid, uuid, jsonb) from anon, authenticated;
revoke execute on function public.calculate_fleet_fuel_for_distance(numeric, text, bigint) from anon, authenticated;
revoke execute on function public.get_player_fleet_speed_multiplier(uuid, uuid) from anon, authenticated;

drop function public.calculate_expedition_time(uuid, text, bigint);
drop function public.calculate_fleet_fuel(uuid, uuid, text, bigint);
drop function public.calculate_fleet_fuel_mixed(uuid, uuid, jsonb);
drop function public.calculate_fleet_time(uuid, uuid, text, bigint);
drop function public.calculate_fleet_fuel_for_distance(numeric, text, bigint);
drop function public.get_player_fleet_speed_multiplier(uuid, uuid);
