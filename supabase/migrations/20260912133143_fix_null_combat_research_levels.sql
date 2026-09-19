CREATE OR REPLACE FUNCTION public.get_combat_ship_attack(p_player_id uuid,p_ship_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT sd.attack * (1 + COALESCE(public.get_player_research_level(p_player_id,'weapons_technology'),0) * 0.10)
FROM public.ship_definitions sd WHERE sd.id=p_ship_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_combat_ship_shield(p_player_id uuid,p_ship_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT sd.shield * (1 + COALESCE(public.get_player_research_level(p_player_id,'shielding_technology'),0) * 0.10)
FROM public.ship_definitions sd WHERE sd.id=p_ship_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_combat_ship_hull(p_player_id uuid,p_ship_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT (sd.hull / 10) * (1 + COALESCE(public.get_player_research_level(p_player_id,'armour_technology'),0) * 0.10)
FROM public.ship_definitions sd WHERE sd.id=p_ship_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_combat_defense_attack(p_player_id uuid,p_defense_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT dd.attack * (1 + COALESCE(public.get_player_research_level(p_player_id,'weapons_technology'),0) * 0.10)
FROM public.defense_definitions dd WHERE dd.id=p_defense_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_combat_defense_shield(p_player_id uuid,p_defense_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT dd.shield * (1 + COALESCE(public.get_player_research_level(p_player_id,'shielding_technology'),0) * 0.10)
FROM public.defense_definitions dd WHERE dd.id=p_defense_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_combat_defense_hull(p_player_id uuid,p_defense_id text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $function$
SELECT (dd.hull / 10) * (1 + COALESCE(public.get_player_research_level(p_player_id,'armour_technology'),0) * 0.10)
FROM public.defense_definitions dd WHERE dd.id=p_defense_id;
$function$;