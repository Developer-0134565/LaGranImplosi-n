CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_fleet RECORD;
    v_universe_id uuid;
    v_outcome text;
    v_roll numeric;
    v_weight_total numeric;
    v_hold_seconds numeric := 0;
    v_delay_multiplier numeric := 1;
    v_speedup_percentage numeric := 0;
    v_speedup_seconds numeric := 0;
    v_flight_seconds numeric := 0;
    v_return_seconds numeric := 0;
    v_reward RECORD;
    v_ship_reward jsonb;
    v_ship_budget RECORD;
    v_ship_id text;
    v_ship_quantity bigint;
    v_battle RECORD;
BEGIN
    SELECT fm.id, fm.player_id, fm.origin_planet_id, fm.status, fm.mission_type,
           fm.started_at, fm.arrives_at
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found', p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION', p_fleet_id; END IF;
    IF v_fleet.status <> 'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution', p_fleet_id; END IF;

    SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id = v_fleet.origin_planet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found for expedition %', p_fleet_id; END IF;

    v_flight_seconds := EXTRACT(EPOCH FROM (v_fleet.arrives_at - v_fleet.started_at));
    IF v_flight_seconds <= 0 THEN RAISE EXCEPTION 'Invalid expedition flight duration for fleet %', p_fleet_id; END IF;

    SELECT es.weight_ships + es.weight_resources + es.weight_delay + es.weight_speedup +
           es.weight_nothing + es.weight_black_hole + es.weight_pirates + es.weight_aliens +
           es.weight_dark_matter + es.weight_merchant + es.weight_items
    INTO v_weight_total
    FROM public.expedition_settings es
    WHERE es.universe_id = v_universe_id;

    IF v_weight_total IS NULL OR v_weight_total <= 0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %', v_universe_id; END IF;

    v_roll := random() * v_weight_total;
    v_outcome := public.select_expedition_outcome(v_universe_id, v_roll);

    IF v_outcome = 'PIRATES' THEN
        SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,battle_id,enemy_ships,ships)
        VALUES(p_fleet_id,v_fleet.player_id,'PIRATES',NULL,1,v_roll,v_weight_total,0,0,0,v_battle.battle_id,v_battle.enemy_ships,v_battle.surviving_ships)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,battle_id=EXCLUDED.battle_id,enemy_ships=EXCLUDED.enemy_ships,ships=EXCLUDED.ships,resolved_at=clock_timestamp();
        UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_flight_seconds) WHERE id=p_fleet_id;
        RETURN 'PIRATES';

    ELSIF v_outcome = 'ALIENS' THEN
        SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,battle_id,enemy_ships,ships,event_type)
        VALUES(p_fleet_id,v_fleet.player_id,'ALIENS',NULL,1,v_roll,v_weight_total,0,0,0,v_battle.battle_id,v_battle.enemy_ships,v_battle.survivors,'ALIENS')
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,battle_id=EXCLUDED.battle_id,enemy_ships=EXCLUDED.enemy_ships,ships=EXCLUDED.ships,event_type='ALIENS',resolved_at=clock_timestamp();
        RETURN 'ALIENS';

    ELSIF v_outcome = 'SHIPS' THEN
        v_ship_reward := public.prepare_expedition_ship_reward_multitype(p_fleet_id);
        SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
        FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP
            IF v_ship_quantity>0 THEN
                INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity)
                ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity;
            END IF;
        END LOOP;
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,ships)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,0,0,0,v_ship_reward)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,ships=EXCLUDED.ships,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'RESOURCES' THEN
        SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
        UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,0,0,0,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,max_resource_find=EXCLUDED.max_resource_find,scaled_resource_find=EXCLUDED.scaled_resource_find,cargo_capacity=EXCLUDED.cargo_capacity,metal=EXCLUDED.metal,crystal=EXCLUDED.crystal,deuterium=EXCLUDED.deuterium,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'DELAY' THEN
        v_delay_multiplier:=public.select_expedition_delay_multiplier();
        v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds,0)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'SPEEDUP' THEN
        v_speedup_percentage:=public.select_expedition_speedup_percentage();
        v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_speedup_percentage,v_roll,v_weight_total,0,0,v_speedup_seconds)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();
        v_return_seconds:=greatest(v_flight_seconds-v_speedup_seconds,1);
        UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_return_seconds) WHERE id=p_fleet_id;
        RETURN 'SPEEDUP';
    ELSE
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total,0,0,0)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();
    END IF;

    UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_flight_seconds+v_hold_seconds)) WHERE id=p_fleet_id;
    RETURN v_outcome;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_fleet_movements()
RETURNS TABLE(fleet_id uuid, previous_status text, new_status text, processed_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE v RECORD; v_duration interval; v_battle uuid; v_last_round integer;
BEGIN
 FOR v IN SELECT fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,fm.destination_galaxy,fm.destination_system,fm.destination_position FROM public.fleet_movements fm WHERE fm.status='OUTBOUND' AND fm.arrives_at<=now() ORDER BY fm.arrives_at FOR UPDATE SKIP LOCKED LOOP
  v_duration:=v.arrives_at-v.started_at;
  UPDATE public.fleet_movements SET status='ARRIVED' WHERE id=v.id;
  IF v.mission_type='RECYCLE' THEN
   PERFORM public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;
  ELSIF v.mission_type='EXPEDITION' THEN
   PERFORM public.resolve_expedition_arrival(v.id);
   SELECT er.battle_id INTO v_battle FROM public.expedition_results er WHERE er.fleet_id=v.id AND er.outcome IN ('PIRATES','ALIENS');
   IF v_battle IS NOT NULL THEN
    SELECT max(cr.round_number) INTO v_last_round FROM public.combat_rounds cr WHERE cr.battle_id=v_battle;
    IF v_last_round IS NULL THEN RAISE EXCEPTION 'Expedition battle % finished without rounds',v_battle; END IF;
    DELETE FROM public.fleet_movement_ships WHERE fleet_id=v.id;
    INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
    SELECT v.id,ciu.unit_id,count(*)::bigint
    FROM public.combat_individual_units ciu
    WHERE ciu.battle_id=v_battle AND ciu.round_number=v_last_round AND ciu.side='ATTACKER' AND ciu.alive=true
    GROUP BY ciu.unit_id;
    UPDATE public.expedition_results er SET battle_id=v_battle,ships=(SELECT COALESCE(jsonb_object_agg(fms2.ship_id,fms2.quantity),'{}'::jsonb) FROM public.fleet_movement_ships fms2 WHERE fms2.fleet_id=v.id),resolved_at=clock_timestamp() WHERE er.fleet_id=v.id;
   END IF;
  ELSIF v.mission_type='TRANSPORT' THEN
   PERFORM public.resolve_transport_arrival(v.id);
  ELSIF v.mission_type='DEPLOY' THEN
   PERFORM public.resolve_deploy_arrival(v.id);
  ELSIF v.mission_type='ATTACK' THEN
   PERFORM public.resolve_attack_arrival(v.id);
  ELSE
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;
  END IF;
  fleet_id:=v.id;previous_status:='OUTBOUND';new_status:=(SELECT status FROM public.fleet_movements WHERE id=v.id);processed_at=now();RETURN NEXT;
 END LOOP;
 FOR v IN SELECT fm.id,fm.status,fm.mission_type FROM public.fleet_movements fm WHERE fm.status='RETURNING' AND fm.returns_at<=now() ORDER BY fm.returns_at FOR UPDATE SKIP LOCKED LOOP
  IF v.mission_type='EXPEDITION' THEN
   PERFORM public.resolve_expedition_return(v.id);
  END IF;
  INSERT INTO public.planet_ships(planet_id,ship_id,quantity)
  SELECT fm.origin_planet_id,fms.ship_id,fms.quantity FROM public.fleet_movements fm JOIN public.fleet_movement_ships fms ON fms.fleet_id=fm.id WHERE fm.id=v.id
  ON CONFLICT(planet_id,ship_id) DO UPDATE SET quantity=public.planet_ships.quantity+EXCLUDED.quantity;
  UPDATE public.fleet_movements SET status='COMPLETED' WHERE id=v.id;
  fleet_id:=v.id;previous_status:='RETURNING';new_status:='COMPLETED';processed_at=now();RETURN NEXT;
 END LOOP;
END;
$function$;