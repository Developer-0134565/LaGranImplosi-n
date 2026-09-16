-- Fleet event-time hardening:
-- 1) expedition item effects are evaluated at the logical arrival timestamp;
-- 2) expedition reward resolution settles the origin economy through arrival before resolving;
-- 3) resource / ship / dark-matter reward multipliers use the fleet arrival event time;
-- 4) legacy two-argument multiplier calls remain compatible.

CREATE OR REPLACE FUNCTION public.get_active_expedition_item_effect(p_player_id uuid,p_planet_id uuid,p_effect_key text,p_at timestamptz)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $function$
    SELECT COALESCE(SUM((eu.effect_snapshot->>'effect_value')::numeric),0)
    FROM public.expedition_item_uses eu
    WHERE eu.player_id=p_player_id
      AND (p_planet_id IS NULL OR eu.planet_id=p_planet_id)
      AND eu.effect_snapshot->>'effect_key'=p_effect_key
      AND (eu.effect_snapshot->>'expires_at' IS NULL OR (eu.effect_snapshot->>'expires_at')::timestamptz > p_at);
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_resource_multiplier(p_fleet_id uuid,p_at timestamptz)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_universe_id uuid; v_player_id uuid; v_planet_id uuid; v_multiplier numeric:=1; v_item_bonus numeric:=0; v_lf_bonus numeric:=0;
BEGIN
 SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
 SELECT COALESCE(reward_multiplier_resources,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
 v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent',p_at);
 v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_reward_percent');
 RETURN COALESCE(v_multiplier,1)*(1+(v_item_bonus+v_lf_bonus)/100);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_ship_reward_multiplier(p_fleet_id uuid,p_at timestamptz)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_player_id uuid;v_planet_id uuid;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;
BEGIN
 SELECT player_id,origin_planet_id INTO v_player_id,v_planet_id FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION';
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
 v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent',p_at);
 v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_ship_reward_percent');
 RETURN 1+(v_item_bonus+v_lf_bonus)/100;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_resource_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_at timestamptz;
BEGIN
 SELECT arrives_at INTO v_at FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION';
 IF v_at IS NULL THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
 RETURN public.calculate_expedition_resource_multiplier(p_fleet_id,v_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_ship_reward_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_at timestamptz;
BEGIN
 SELECT arrives_at INTO v_at FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION';
 IF v_at IS NULL THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
 RETURN public.calculate_expedition_ship_reward_multiplier(p_fleet_id,v_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_dark_matter_amount(p_fleet_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_universe_id uuid;v_player_id uuid;v_planet_id uuid;v_at timestamptz;v_multiplier numeric:=1;v_class_multiplier numeric:=1;v_tier_multiplier numeric:=1;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;v_base numeric;
BEGIN
 SELECT fm.player_id,fm.origin_planet_id,fm.arrives_at,p.universe_id INTO v_player_id,v_planet_id,v_at,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
 SELECT COALESCE(reward_multiplier_dark_matter,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
 SELECT COALESCE(dark_matter_multiplier,1) INTO v_class_multiplier FROM public.player_expedition_modifiers WHERE player_id=v_player_id;
 SELECT COALESCE(reward_multiplier,1) INTO v_tier_multiplier FROM public.expedition_results WHERE fleet_id=p_fleet_id;
 v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent',v_at);
 v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_dm_percent');
 v_base:=floor(public.expedition_event_random(p_fleet_id,'dark_matter_amount')*81)+20;
 RETURN greatest(20,round(v_base*COALESCE(v_multiplier,1)*COALESCE(v_class_multiplier,1)*COALESCE(v_tier_multiplier,1)*(1+(v_item_bonus+v_lf_bonus)/100)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_fleet RECORD;v_universe_id uuid;v_outcome text;v_roll numeric;v_weight_total numeric;v_actual_hold_seconds numeric:=3600;v_hold_seconds numeric:=0;v_delay_multiplier numeric:=1;v_speedup_percentage numeric:=0;v_speedup_seconds numeric:=0;v_flight_seconds numeric:=0;v_return_seconds numeric:=0;v_reward RECORD;v_ship_reward jsonb;v_ship_budget RECORD;v_ship_id text;v_ship_quantity bigint;v_battle RECORD;v_dm numeric:=0;v_merchant RECORD;v_item jsonb;v_existing_outcome text;
BEGIN
 SELECT fm.id,fm.player_id,fm.origin_planet_id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,COALESCE(fm.expedition_hold_seconds,3600) AS expedition_hold_seconds INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id;END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id;END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution',p_fleet_id;END IF;
 SELECT er.outcome INTO v_existing_outcome FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id FOR UPDATE;
 IF FOUND AND v_existing_outcome IS NOT NULL THEN RETURN v_existing_outcome;END IF;
 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=v_fleet.origin_planet_id;
 -- Settle the origin economy exactly through the logical arrival event before rewards.
 PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id,v_fleet.arrives_at);
 v_actual_hold_seconds:=GREATEST(v_fleet.expedition_hold_seconds,0);v_flight_seconds:=GREATEST(EXTRACT(EPOCH FROM(v_fleet.arrives_at-v_fleet.started_at)),1);
 SELECT es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing+es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter+es.weight_merchant+es.weight_items INTO v_weight_total FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
 IF v_weight_total IS NULL OR v_weight_total<=0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %',v_universe_id;END IF;
 v_roll:=public.expedition_event_random(p_fleet_id,'outcome')*v_weight_total;v_outcome:=public.select_expedition_outcome(v_universe_id,v_roll);
 IF v_outcome='PIRATES' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,resolved_at,event_type,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,'PIRATES',v_battle.battle_id,v_battle.enemy_ships,v_battle.surviving_ships,v_fleet.arrives_at,'PIRATES',v_roll,v_weight_total) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='ALIENS' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,v_fleet.arrives_at,'ALIENS',v_roll,v_weight_total) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='SHIPS' THEN
   v_ship_reward:=public.prepare_expedition_ship_reward_multitype(p_fleet_id);
   SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
   FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP IF v_ship_quantity>0 THEN INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity) ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity;END IF;END LOOP;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,ships) VALUES(p_fleet_id,v_fleet.player_id,'SHIPS',v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,v_ship_reward) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='RESOURCES' THEN
   SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
   UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium) VALUES(p_fleet_id,v_fleet.player_id,'RESOURCES',v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='BLACK_HOLE' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_black_hole(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,random_roll,weight_total,lost_ships,ships,loss_percentage,resolved_at,event_type) VALUES(p_fleet_id,v_fleet.player_id,'BLACK_HOLE',v_roll,v_weight_total,v_battle.lost_ships,v_battle.surviving_ships,v_battle.loss_percentage,v_fleet.arrives_at,'BLACK_HOLE') ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='DARK_MATTER' THEN
   v_dm:=public.calculate_expedition_dark_matter_amount(p_fleet_id);UPDATE public.players SET dark_matter=COALESCE(dark_matter,0)+v_dm WHERE id=v_fleet.player_id;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,dark_matter) VALUES(p_fleet_id,v_fleet.player_id,'DARK_MATTER',1,v_roll,v_weight_total,v_dm) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='MERCHANT' THEN
   SELECT * INTO v_merchant FROM public.resolve_expedition_merchant(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,merchant_resource,merchant_metal_rate,merchant_crystal_rate,merchant_deuterium_rate) VALUES(p_fleet_id,v_fleet.player_id,'MERCHANT',1,v_roll,v_weight_total,v_merchant.merchant_resource,v_merchant.metal_rate,v_merchant.crystal_rate,v_merchant.deuterium_rate) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='ITEMS' THEN
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,resolved_at,event_type) VALUES(p_fleet_id,v_fleet.player_id,'ITEMS',1,v_roll,v_weight_total,v_fleet.arrives_at,'ITEMS') ON CONFLICT(fleet_id) DO NOTHING;v_item:=public.resolve_expedition_item(p_fleet_id);
 ELSIF v_outcome='DELAY' THEN
   v_delay_multiplier:=public.select_expedition_delay_multiplier(p_fleet_id);v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds) VALUES(p_fleet_id,v_fleet.player_id,'DELAY',v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='SPEEDUP' THEN
   v_speedup_percentage:=public.select_expedition_speedup_percentage(p_fleet_id);v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage);v_return_seconds:=GREATEST(v_flight_seconds-v_speedup_seconds,1);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,speedup_seconds) VALUES(p_fleet_id,v_fleet.player_id,'SPEEDUP',v_speedup_percentage,v_roll,v_weight_total,v_speedup_seconds) ON CONFLICT(fleet_id) DO NOTHING;
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_return_seconds)) WHERE id=p_fleet_id;RETURN 'SPEEDUP';
 ELSE
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total) ON CONFLICT(fleet_id) DO NOTHING;
 END IF;
 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_flight_seconds+v_hold_seconds)) WHERE id=p_fleet_id;
 RETURN v_outcome;
END;
$function$;