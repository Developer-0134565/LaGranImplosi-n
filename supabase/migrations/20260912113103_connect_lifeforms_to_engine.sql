CREATE OR REPLACE FUNCTION public.get_lifeform_research_population_requirement(p_slot integer)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
SELECT CASE p_slot
WHEN 1 THEN 200000 WHEN 2 THEN 300000 WHEN 3 THEN 400000 WHEN 4 THEN 500000 WHEN 5 THEN 750000 WHEN 6 THEN 1000000
WHEN 7 THEN 1200000 WHEN 8 THEN 3000000 WHEN 9 THEN 5000000 WHEN 10 THEN 7000000 WHEN 11 THEN 9000000 WHEN 12 THEN 11000000
WHEN 13 THEN 13000000 WHEN 14 THEN 26000000 WHEN 15 THEN 56000000 WHEN 16 THEN 112000000 WHEN 17 THEN 224000000 WHEN 18 THEN 448000000 ELSE 0 END;
$function$;

CREATE OR REPLACE FUNCTION public.start_lifeform_research(p_planet_id uuid,p_research_id text)
RETURNS jsonb LANGUAGE plpgsql AS $function$
DECLARE v_def public.lifeform_research_definitions%ROWTYPE;v_active text;v_level integer:=0;v_target integer;v_id uuid;v_player uuid;v_discovered boolean;v_population numeric;v_previous_slots integer;
BEGIN
SELECT * INTO v_def FROM public.lifeform_research_definitions WHERE id=p_research_id;IF NOT FOUND THEN RAISE EXCEPTION 'Unknown lifeform research %',p_research_id;END IF;
SELECT lifeform_id,player_id INTO v_active,v_player FROM public.planets p JOIN public.planet_lifeforms pl ON pl.planet_id=p.id AND pl.active=true WHERE p.id=p_planet_id;IF v_active IS NULL THEN RAISE EXCEPTION 'No active lifeform';END IF;
SELECT COALESCE(bool_or(discovered),false) INTO v_discovered FROM public.player_lifeform_discoveries WHERE player_id=v_player AND lifeform_id=v_def.lifeform_id;IF NOT v_discovered THEN RAISE EXCEPTION 'Lifeform % has not been discovered',v_def.lifeform_id;END IF;
SELECT population_t1+population_t2+population_t3 INTO v_population FROM public.planet_lifeforms WHERE planet_id=p_planet_id;IF COALESCE(v_population,0)<public.get_lifeform_research_population_requirement(v_def.slot) THEN RAISE EXCEPTION 'Population %. Required for slot %: %',COALESCE(v_population,0),v_def.slot,public.get_lifeform_research_population_requirement(v_def.slot);END IF;
IF v_def.tier>1 THEN SELECT count(*) INTO v_previous_slots FROM public.planet_lifeform_research WHERE planet_id=p_planet_id AND slot BETWEEN ((v_def.tier-1)*6-5) AND ((v_def.tier-1)*6);IF v_previous_slots<6 THEN RAISE EXCEPTION 'Tier % requires all previous 6 research slots',v_def.tier;END IF;END IF;
SELECT COALESCE(MAX(level),0) INTO v_level FROM public.planet_lifeform_research WHERE planet_id=p_planet_id AND slot=v_def.slot;v_target:=v_level+1;IF v_target>v_def.max_level THEN RAISE EXCEPTION 'Max level reached';END IF;
INSERT INTO public.planet_lifeform_research(planet_id,slot,research_id,level) VALUES(p_planet_id,v_def.slot,p_research_id,v_target) ON CONFLICT(planet_id,slot) DO UPDATE SET research_id=EXCLUDED.research_id,level=EXCLUDED.level,updated_at=now();
INSERT INTO public.lifeform_research_queue(planet_id,research_id,target_level,started_at,finishes_at,status) VALUES(p_planet_id,p_research_id,v_target,now(),now(),'COMPLETED') RETURNING id INTO v_id;
RETURN jsonb_build_object('queue_id',v_id,'research_id',p_research_id,'slot',v_def.slot,'level',v_target,'completed',true,'accelerated',true);
END;$function$;

-- Lifeform research bonuses are empire-wide once active on the planet where they were developed.
CREATE OR REPLACE FUNCTION public.get_player_lifeform_effect(p_player_id uuid,p_effect_key text)
RETURNS numeric LANGUAGE sql STABLE AS $function$
SELECT public.get_active_lifeform_research_effect(p_player_id,p_effect_key);
$function$;

-- Existing expedition engine: Lifeform research stacks with class/item modifiers.
CREATE OR REPLACE FUNCTION public.calculate_expedition_resource_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_universe_id uuid;v_player_id uuid;v_planet_id uuid;v_multiplier numeric:=1;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;
BEGIN SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id;END IF;SELECT COALESCE(reward_multiplier_resources,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_reward_percent');RETURN COALESCE(v_multiplier,1)*(1+(v_item_bonus+v_lf_bonus)/100);END;$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_ship_reward_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_player_id uuid;v_planet_id uuid;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;
BEGIN SELECT player_id,origin_planet_id INTO v_player_id,v_planet_id FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION';IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id;END IF;v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_ship_reward_percent');RETURN 1+(v_item_bonus+v_lf_bonus)/100;END;$function$;

CREATE OR REPLACE FUNCTION public.get_player_fleet_speed_multiplier(p_player_id uuid,p_planet_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $function$
SELECT 1+
(
 COALESCE(public.get_active_expedition_item_effect(p_player_id,p_planet_id,'fleet_speed_percent'),0)+
 COALESCE(public.get_active_lifeform_research_effect(p_player_id,'fleet_speed_percent'),0)
)/100;
$function$;
