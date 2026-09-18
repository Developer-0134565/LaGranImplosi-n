BEGIN;

-- These SECURITY DEFINER helpers are internal implementation details.
-- Keep them callable by trusted database code, but not directly through the Data API.
REVOKE EXECUTE ON FUNCTION public.complete_building(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.load_fleet_cargo(uuid,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_defense_attack(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_defense_hull(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_defense_shield(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_ship_attack(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_ship_hull(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_combat_ship_shield(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_player_research_level(uuid,text) FROM PUBLIC, anon, authenticated;

COMMIT;
