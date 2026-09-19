CREATE OR REPLACE FUNCTION public.resolve_expedition_item(p_fleet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_fleet public.fleet_movements%ROWTYPE;
    v_item_id text;
    v_item public.expedition_item_definitions%ROWTYPE;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id=p_fleet_id AND mission_type='EXPEDITION'
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id; END IF;

    v_item_id := public.select_expedition_item();
    SELECT * INTO v_item
    FROM public.expedition_item_definitions
    WHERE id=v_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % is not active', v_item_id; END IF;

    INSERT INTO public.player_expedition_items(player_id,item_id,quantity,expires_at,active)
    VALUES(v_fleet.player_id,v_item_id,1,NULL,true);

    INSERT INTO public.expedition_results(
        fleet_id,player_id,outcome,reward_multiplier,item_id,item_quantity,resolved_at
    ) VALUES(
        p_fleet_id,v_fleet.player_id,'ITEMS',1,v_item_id,1,clock_timestamp()
    )
    ON CONFLICT(fleet_id) DO UPDATE SET
        outcome=EXCLUDED.outcome,
        reward_multiplier=EXCLUDED.reward_multiplier,
        item_id=EXCLUDED.item_id,
        item_quantity=EXCLUDED.item_quantity,
        resolved_at=EXCLUDED.resolved_at;

    RETURN jsonb_build_object(
        'item_id',v_item_id,
        'name',v_item.name,
        'category',v_item.category,
        'effect_key',v_item.effect_key,
        'effect_value',v_item.effect_value,
        'duration_seconds',v_item.duration_seconds
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.use_expedition_item(
    p_player_id uuid,
    p_item_id text,
    p_planet_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_item public.expedition_item_definitions%ROWTYPE;
    v_inventory public.player_expedition_items%ROWTYPE;
    v_expiry timestamptz;
BEGIN
    SELECT * INTO v_item
    FROM public.expedition_item_definitions
    WHERE id=p_item_id AND active=true;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or inactive item %',p_item_id; END IF;

    IF p_planet_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.planets
        WHERE id=p_planet_id AND player_id=p_player_id AND is_destroyed=false
    ) THEN
        RAISE EXCEPTION 'Planet % does not belong to player %',p_planet_id,p_player_id;
    END IF;

    SELECT * INTO v_inventory
    FROM public.player_expedition_items
    WHERE player_id=p_player_id AND item_id=p_item_id AND active=true AND quantity>0
    ORDER BY acquired_at
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item % not available for player %',p_item_id,p_player_id; END IF;

    UPDATE public.player_expedition_items
    SET quantity=quantity-1,
        active=(quantity-1)>0
    WHERE id=v_inventory.id;

    v_expiry := CASE
        WHEN v_item.duration_seconds>0 THEN now()+make_interval(secs=>v_item.duration_seconds)
        ELSE NULL
    END;

    INSERT INTO public.expedition_item_uses(
        player_id,item_id,planet_id,quantity,effect_snapshot
    ) VALUES(
        p_player_id,p_item_id,p_planet_id,1,
        jsonb_build_object(
            'effect_key',v_item.effect_key,
            'effect_value',v_item.effect_value,
            'expires_at',v_expiry
        )
    );

    RETURN jsonb_build_object(
        'item_id',p_item_id,
        'effect_key',v_item.effect_key,
        'effect_value',v_item.effect_value,
        'expires_at',v_expiry
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_active_expedition_item_effect(
    p_player_id uuid,
    p_planet_id uuid,
    p_effect_key text
)
RETURNS numeric
LANGUAGE sql
STABLE
AS $function$
    SELECT COALESCE(SUM((eu.effect_snapshot->>'effect_value')::numeric),0)
    FROM public.expedition_item_uses eu
    WHERE eu.player_id=p_player_id
      AND (p_planet_id IS NULL OR eu.planet_id=p_planet_id)
      AND eu.effect_snapshot->>'effect_key'=p_effect_key
      AND (
          eu.effect_snapshot->>'expires_at' IS NULL
          OR (eu.effect_snapshot->>'expires_at')::timestamptz > now()
      );
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
 v_fleet RECORD; v_universe_id uuid; v_outcome text; v_roll numeric; v_weight_total numeric;
 v_actual_hold_seconds numeric:=3600; v_hold_seconds numeric:=0; v_delay_multiplier numeric:=1;
 v_speedup_percentage numeric:=0; v_speedup_seconds numeric:=0; v_flight_seconds numeric:=0; v_return_seconds numeric:=0;
 v_reward RECORD; v_ship_reward jsonb; v_ship_budget RECORD; v_ship_id text; v_ship_quantity bigint;
 v_battle RECORD; v_dm numeric:=0; v_merchant RECORD; v_item jsonb;
BEGIN
 SELECT fm.id,fm.player_id,fm.origin_planet_id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,COALESCE(fm.expedition_hold_seconds,3600) AS expedition_hold_seconds
 INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution',p_fleet_id; END IF;
 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=v_fleet.origin_planet_id;
 v_actual_hold_seconds:=GREATEST(v_fleet.expedition_hold_seconds,0);
 v_flight_seconds:=GREATEST(EXTRACT(EPOCH FROM(v_fleet.arrives_at-v_fleet.started_at)),1);
 SELECT es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing+es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter+es.weight_merchant+es.weight_items INTO v_weight_total FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
 IF v_weight_total IS NULL OR v_weight_total<=0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %',v_universe_id; END IF;
 v_roll:=random()*v_weight_total; v_outcome:=public.select_expedition_outcome(v_universe_id,v_roll);

 IF v_outcome='PIRATES' THEN
  SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
  UPDATE public.expedition_results SET outcome='PIRATES',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.surviving_ships,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id;
 ELSIF v_outcome='ALIENS' THEN
  SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
  UPDATE public.expedition_results SET outcome='ALIENS',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.survivors,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id;
 ELSIF v_outcome='SHIPS' THEN
  v_ship_reward:=public.prepare_expedition_ship_reward_multitype(p_fleet_id);
  SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
  FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP
   IF v_ship_quantity>0 THEN INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity) ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity; END IF;
  END LOOP;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,ships) VALUES(p_fleet_id,v_fleet.player_id,'SHIPS',v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,v_ship_reward) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,ships=EXCLUDED.ships,resolved_at=clock_timestamp();
 ELSIF v_outcome='RESOURCES' THEN
  SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
  UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium) VALUES(p_fleet_id,v_fleet.player_id,'RESOURCES',v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,max_resource_find=EXCLUDED.max_resource_find,scaled_resource_find=EXCLUDED.scaled_resource_find,cargo_capacity=EXCLUDED.cargo_capacity,metal=EXCLUDED.metal,crystal=EXCLUDED.crystal,deuterium=EXCLUDED.deuterium,resolved_at=clock_timestamp();
 ELSIF v_outcome='BLACK_HOLE' THEN
  PERFORM public.resolve_expedition_black_hole(p_fleet_id); RETURN 'BLACK_HOLE';
 ELSIF v_outcome='DARK_MATTER' THEN
  v_dm:=public.calculate_expedition_dark_matter_amount(p_fleet_id); UPDATE public.players SET dark_matter=COALESCE(dark_matter,0)+v_dm WHERE id=v_fleet.player_id;
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,dark_matter) VALUES(p_fleet_id,v_fleet.player_id,'DARK_MATTER',1,v_roll,v_weight_total,v_dm) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,dark_matter=EXCLUDED.dark_matter,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,resolved_at=clock_timestamp();
 ELSIF v_outcome='MERCHANT' THEN
  SELECT * INTO v_merchant FROM public.resolve_expedition_merchant(p_fleet_id);
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,merchant_resource,merchant_metal_rate,merchant_crystal_rate,merchant_deuterium_rate) VALUES(p_fleet_id,v_fleet.player_id,'MERCHANT',1,v_roll,v_weight_total,v_merchant.merchant_resource,v_merchant.metal_rate,v_merchant.crystal_rate,v_merchant.deuterium_rate) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,merchant_resource=EXCLUDED.merchant_resource,merchant_metal_rate=EXCLUDED.metal_rate,merchant_crystal_rate=EXCLUDED.crystal_rate,merchant_deuterium_rate=EXCLUDED.deuterium_rate,resolved_at=clock_timestamp();
 ELSIF v_outcome='ITEMS' THEN
  v_item:=public.resolve_expedition_item(p_fleet_id);
 ELSIF v_outcome='DELAY' THEN
  v_delay_multiplier:=public.select_expedition_delay_multiplier();
  v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier);
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds) VALUES(p_fleet_id,v_fleet.player_id,'DELAY',v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,resolved_at=clock_timestamp();
 ELSIF v_outcome='SPEEDUP' THEN
  v_speedup_percentage:=public.select_expedition_speedup_percentage();
  v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage);
  v_return_seconds:=GREATEST(v_flight_seconds-v_speedup_seconds,1);
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,speedup_seconds) VALUES(p_fleet_id,v_fleet.player_id,'SPEEDUP',v_speedup_percentage,v_roll,v_weight_total,v_speedup_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();
  UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_return_seconds)) WHERE id=p_fleet_id;
  RETURN 'SPEEDUP';
 ELSE
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,resolved_at=clock_timestamp();
 END IF;

 UPDATE public.fleet_movements
 SET status='RETURNING',
     returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_flight_seconds+v_hold_seconds))
 WHERE id=p_fleet_id;
 RETURN v_outcome;
END;
$function$;
