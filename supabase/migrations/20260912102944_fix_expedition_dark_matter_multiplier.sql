CREATE OR REPLACE FUNCTION public.calculate_expedition_dark_matter_amount(p_fleet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_universe_id uuid;
    v_player_id uuid;
    v_multiplier numeric := 1;
    v_class_multiplier numeric := 1;
    v_tier_multiplier numeric := 1;
    v_base numeric;
BEGIN
    SELECT fm.player_id,p.universe_id INTO v_player_id,v_universe_id
    FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id
    WHERE fm.id=p_fleet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;

    SELECT COALESCE(es.reward_multiplier_dark_matter,1) INTO v_multiplier
    FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
    v_multiplier:=COALESCE(v_multiplier,1);

    SELECT COALESCE(pem.dark_matter_multiplier,1) INTO v_class_multiplier
    FROM public.player_expedition_modifiers pem WHERE pem.player_id=v_player_id;
    v_class_multiplier:=COALESCE(v_class_multiplier,1);

    SELECT COALESCE(er.reward_multiplier,1) INTO v_tier_multiplier
    FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id;
    v_tier_multiplier:=COALESCE(v_tier_multiplier,1);

    v_base:=floor(random()*81)+20;
    RETURN greatest(20,round(v_base*v_multiplier*v_class_multiplier*v_tier_multiplier));
END;
$function$;

-- The amount itself belongs in expedition_results.dark_matter; reward_multiplier remains a multiplier.
CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $function$
DECLARE
 v_fleet RECORD; v_universe_id uuid; v_outcome text; v_roll numeric; v_weight_total numeric; v_hold_seconds numeric:=0; v_delay_multiplier numeric:=1; v_speedup_percentage numeric:=0; v_speedup_seconds numeric:=0; v_flight_seconds numeric:=0; v_return_seconds numeric:=0; v_reward RECORD; v_ship_reward jsonb; v_ship_budget RECORD; v_ship_id text; v_ship_quantity bigint; v_battle RECORD; v_dm numeric:=0;
BEGIN
 SELECT fm.id,fm.player_id,fm.origin_planet_id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution',p_fleet_id; END IF;
 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=v_fleet.origin_planet_id;
 v_flight_seconds:=EXTRACT(EPOCH FROM(v_fleet.arrives_at-v_fleet.started_at));
 SELECT es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing+es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter+es.weight_merchant+es.weight_items INTO v_weight_total FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
 IF v_weight_total IS NULL OR v_weight_total<=0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %',v_universe_id; END IF;
 v_roll:=random()*v_weight_total; v_outcome:=public.select_expedition_outcome(v_universe_id,v_roll);
 IF v_outcome='PIRATES' THEN
  SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
  UPDATE public.expedition_results SET outcome='PIRATES',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.surviving_ships,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id;
  UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_flight_seconds) WHERE id=p_fleet_id; RETURN 'PIRATES';
 ELSIF v_outcome='ALIENS' THEN
  SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
  UPDATE public.expedition_results SET outcome='ALIENS',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.survivors,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id;
  UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_flight_seconds) WHERE id=p_fleet_id; RETURN 'ALIENS';
 ELSIF v_outcome='SHIPS' THEN
  v_ship_reward:=public.prepare_expedition_ship_reward_multitype(p_fleet_id); SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
  FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP IF v_ship_quantity>0 THEN INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity) ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity; END IF; END LOOP;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,ships) VALUES(p_fleet_id,v_fleet.player_id,'SHIPS',v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,v_ship_reward) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,ships=EXCLUDED.ships,resolved_at=clock_timestamp();
 ELSIF v_outcome='RESOURCES' THEN
  SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
  UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium) VALUES(p_fleet_id,v_fleet.player_id,'RESOURCES',v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,max_resource_find=EXCLUDED.max_resource_find,scaled_resource_find=EXCLUDED.scaled_resource_find,cargo_capacity=EXCLUDED.cargo_capacity,metal=EXCLUDED.metal,crystal=EXCLUDED.crystal,deuterium=EXCLUDED.deuterium,resolved_at=clock_timestamp();
 ELSIF v_outcome='BLACK_HOLE' THEN
  PERFORM public.resolve_expedition_black_hole(p_fleet_id); RETURN 'BLACK_HOLE';
 ELSIF v_outcome='DARK_MATTER' THEN
  v_dm:=public.calculate_expedition_dark_matter_amount(p_fleet_id);
  UPDATE public.players SET dark_matter=COALESCE(dark_matter,0)+v_dm WHERE id=v_fleet.player_id;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,dark_matter) VALUES(p_fleet_id,v_fleet.player_id,'DARK_MATTER',1,v_roll,v_weight_total,v_dm) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=1,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,dark_matter=EXCLUDED.dark_matter,resolved_at=clock_timestamp();
 ELSIF v_outcome='DELAY' THEN
  v_delay_multiplier:=public.select_expedition_delay_multiplier(); v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier); INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds) VALUES(p_fleet_id,v_fleet.player_id,'DELAY',v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,resolved_at=clock_timestamp();
 ELSIF v_outcome='SPEEDUP' THEN
  v_speedup_percentage:=public.select_expedition_speedup_percentage(); v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage); v_return_seconds:=greatest(v_flight_seconds-v_speedup_seconds,1); INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,speedup_seconds) VALUES(p_fleet_id,v_fleet.player_id,'SPEEDUP',v_speedup_percentage,v_roll,v_weight_total,v_speedup_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp(); UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_return_seconds) WHERE id=p_fleet_id; RETURN 'SPEEDUP';
 ELSE
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=1,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,resolved_at=clock_timestamp();
 END IF;
 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_flight_seconds+v_hold_seconds)) WHERE id=p_fleet_id; RETURN v_outcome;
END;
$function$;