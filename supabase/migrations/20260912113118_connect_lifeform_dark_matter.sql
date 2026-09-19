CREATE OR REPLACE FUNCTION public.calculate_expedition_dark_matter_amount(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE AS $function$
DECLARE v_universe_id uuid;v_player_id uuid;v_planet_id uuid;v_multiplier numeric:=1;v_class_multiplier numeric:=1;v_tier_multiplier numeric:=1;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;v_base numeric;
BEGIN
SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
SELECT COALESCE(reward_multiplier_dark_matter,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
SELECT COALESCE(dark_matter_multiplier,1) INTO v_class_multiplier FROM public.player_expedition_modifiers WHERE player_id=v_player_id;
SELECT COALESCE(reward_multiplier,1) INTO v_tier_multiplier FROM public.expedition_results WHERE fleet_id=p_fleet_id;
v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');
v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_dm_percent');
v_base:=floor(random()*81)+20;
RETURN greatest(20,round(v_base*COALESCE(v_multiplier,1)*COALESCE(v_class_multiplier,1)*COALESCE(v_tier_multiplier,1)*(1+(v_item_bonus+v_lf_bonus)/100)));
END;$function$;