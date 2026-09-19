CREATE OR REPLACE FUNCTION public.resolve_expedition_merchant(p_fleet_id uuid)
RETURNS TABLE(merchant_resource text, metal_rate numeric, crystal_rate numeric, deuterium_rate numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
    v_fleet record;
    v_offer record;
    v_existing record;
BEGIN
    SELECT fm.id,fm.player_id,fm.mission_type,fm.status INTO v_fleet
    FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;

    SELECT * INTO v_existing FROM public.player_expedition_merchants
    WHERE player_id=v_fleet.player_id AND active=true FOR UPDATE;

    SELECT * INTO v_offer FROM public.select_expedition_merchant_offer();

    IF FOUND AND v_existing.player_id IS NOT NULL THEN
        -- QoL rule: an expedition merchant never changes what it buys;
        -- later encounters can only improve its rate up to 3:2:1.
        INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active)
        VALUES(v_fleet.player_id,v_existing.resource,
               GREATEST(v_existing.metal_rate,v_offer.metal_rate),
               GREATEST(v_existing.crystal_rate,v_offer.crystal_rate),1,'EXPEDITION',true)
        ON CONFLICT(player_id) DO UPDATE SET
            resource=public.player_expedition_merchants.resource,
            metal_rate=LEAST(3,GREATEST(public.player_expedition_merchants.metal_rate,EXCLUDED.metal_rate)),
            crystal_rate=LEAST(2,GREATEST(public.player_expedition_merchants.crystal_rate,EXCLUDED.crystal_rate)),
            deuterium_rate=1,
            active=true,
            source='EXPEDITION',
            updated_at=now();
    ELSE
        INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active)
        VALUES(v_fleet.player_id,v_offer.resource,v_offer.metal_rate,v_offer.crystal_rate,1,'EXPEDITION',true)
        ON CONFLICT(player_id) DO UPDATE SET
            resource=EXCLUDED.resource,
            metal_rate=EXCLUDED.metal_rate,
            crystal_rate=EXCLUDED.crystal_rate,
            deuterium_rate=1,
            active=true,
            source='EXPEDITION',
            updated_at=now();
    END IF;

    RETURN QUERY SELECT pem.resource,pem.metal_rate,pem.crystal_rate,pem.deuterium_rate
    FROM public.player_expedition_merchants pem WHERE pem.player_id=v_fleet.player_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_expedition_merchant_trade(
    p_player_id uuid,
    p_planet_id uuid,
    p_sell_resource text,
    p_sell_amount numeric
)
RETURNS TABLE(sold numeric,bought numeric,bought_resource text,remaining_merchant boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
    v_merchant record;
    v_res record;
    v_caps record;
    v_buy numeric;
    v_ratio numeric;
    v_capacity numeric;
    v_resource text;
BEGIN
    IF p_sell_amount <= 0 THEN RAISE EXCEPTION 'Sell amount must be positive'; END IF;
    IF p_sell_resource NOT IN ('METAL','CRYSTAL','DEUTERIUM') THEN RAISE EXCEPTION 'Invalid sell resource'; END IF;

    SELECT * INTO v_merchant FROM public.player_expedition_merchants
    WHERE player_id=p_player_id AND active=true FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No active merchant for player %',p_player_id; END IF;
    IF p_sell_resource=v_merchant.resource THEN RAISE EXCEPTION 'Merchant buys %, not %',v_merchant.resource,p_sell_resource; END IF;

    SELECT * INTO v_res FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Planet resources not found'; END IF;
    SELECT * INTO v_caps FROM public.calculate_planet_storage(p_planet_id);

    IF p_sell_resource='METAL' AND v_res.metal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient metal'; END IF;
    IF p_sell_resource='CRYSTAL' AND v_res.crystal < p_sell_amount THEN RAISE EXCEPTION 'Insufficient crystal'; END IF;
    IF p_sell_resource='DEUTERIUM' AND v_res.deuterium < p_sell_amount THEN RAISE EXCEPTION 'Insufficient deuterium'; END IF;

    v_resource:=v_merchant.resource;
    IF v_resource='METAL' THEN v_ratio:=v_merchant.metal_rate; v_capacity:=GREATEST(0,v_caps.metal_capacity-v_res.metal);
    ELSIF v_resource='CRYSTAL' THEN v_ratio:=v_merchant.crystal_rate; v_capacity:=GREATEST(0,v_caps.crystal_capacity-v_res.crystal);
    ELSE v_ratio:=v_merchant.deuterium_rate; v_capacity:=GREATEST(0,v_caps.deuterium_capacity-v_res.deuterium);
    END IF;

    IF v_resource='METAL' THEN
        IF p_sell_resource='CRYSTAL' THEN v_buy:=floor(p_sell_amount*(v_ratio/v_merchant.crystal_rate));
        ELSIF p_sell_resource='DEUTERIUM' THEN v_buy:=floor(p_sell_amount*v_ratio); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    ELSIF v_resource='CRYSTAL' THEN
        IF p_sell_resource='METAL' THEN v_buy:=floor(p_sell_amount*(v_ratio/v_merchant.metal_rate));
        ELSIF p_sell_resource='DEUTERIUM' THEN v_buy:=floor(p_sell_amount*v_ratio); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    ELSE
        IF p_sell_resource='METAL' THEN v_buy:=floor(p_sell_amount/v_merchant.metal_rate);
        ELSIF p_sell_resource='CRYSTAL' THEN v_buy:=floor(p_sell_amount/v_merchant.crystal_rate); ELSE RAISE EXCEPTION 'Invalid merchant trade'; END IF;
    END IF;

    v_buy:=LEAST(v_buy,v_capacity);
    IF v_buy <= 0 THEN RAISE EXCEPTION 'Insufficient storage for merchant purchase'; END IF;

    -- Recalculate the exact amount spent so the trade never creates resources.
    IF v_resource='METAL' THEN
        IF p_sell_resource='CRYSTAL' THEN p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.crystal_rate));
        ELSE p_sell_amount:=LEAST(p_sell_amount,floor(v_buy/v_merchant.metal_rate)); END IF;
    ELSIF v_resource='CRYSTAL' THEN
        IF p_sell_resource='METAL' THEN p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.metal_rate));
        ELSE p_sell_amount:=LEAST(p_sell_amount,floor(v_buy/v_merchant.crystal_rate)); END IF;
    ELSE
        p_sell_amount:=LEAST(p_sell_amount,floor(v_buy*v_merchant.metal_rate));
    END IF;

    IF p_sell_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal-p_sell_amount,updated_at=now() WHERE planet_id=p_planet_id;
    ELSIF p_sell_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal-p_sell_amount,updated_at=now() WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium-p_sell_amount,updated_at=now() WHERE planet_id=p_planet_id; END IF;

    IF v_resource='METAL' THEN UPDATE public.planet_resources SET metal=metal+v_buy,updated_at=now() WHERE planet_id=p_planet_id;
    ELSIF v_resource='CRYSTAL' THEN UPDATE public.planet_resources SET crystal=crystal+v_buy,updated_at=now() WHERE planet_id=p_planet_id;
    ELSE UPDATE public.planet_resources SET deuterium=deuterium+v_buy,updated_at=now() WHERE planet_id=p_planet_id; END IF;

    UPDATE public.player_expedition_merchants SET active=false,updated_at=now() WHERE player_id=p_player_id;
    sold:=p_sell_amount; bought:=v_buy; bought_resource:=v_resource; remaining_merchant:=false; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
 v_fleet RECORD; v_universe_id uuid; v_outcome text; v_roll numeric; v_weight_total numeric;
 v_hold_seconds numeric:=0; v_delay_multiplier numeric:=1; v_speedup_percentage numeric:=0; v_speedup_seconds numeric:=0;
 v_flight_seconds numeric:=0; v_return_seconds numeric:=0; v_reward RECORD; v_ship_reward jsonb; v_ship_budget RECORD;
 v_ship_id text; v_ship_quantity bigint; v_battle RECORD; v_dm numeric:=0; v_merchant RECORD;
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
  SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id); UPDATE public.expedition_results SET outcome='PIRATES',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.surviving_ships,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id; UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_flight_seconds) WHERE id=p_fleet_id; RETURN 'PIRATES';
 ELSIF v_outcome='ALIENS' THEN
  SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id); UPDATE public.expedition_results SET outcome='ALIENS',battle_id=v_battle.battle_id,enemy_ships=v_battle.enemy_ships,ships=v_battle.survivors,resolved_at=clock_timestamp() WHERE fleet_id=p_fleet_id; UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_flight_seconds) WHERE id=p_fleet_id; RETURN 'ALIENS';
 ELSIF v_outcome='SHIPS' THEN
  v_ship_reward:=public.prepare_expedition_ship_reward_multitype(p_fleet_id); SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE; FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP IF v_ship_quantity>0 THEN INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity) ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity; END IF; END LOOP; INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,ships) VALUES(p_fleet_id,v_fleet.player_id,'SHIPS',v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,v_ship_reward) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,ships=EXCLUDED.ships,resolved_at=clock_timestamp();
 ELSIF v_outcome='RESOURCES' THEN
  SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id); UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id; INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium) VALUES(p_fleet_id,v_fleet.player_id,'RESOURCES',v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,max_resource_find=EXCLUDED.max_resource_find,scaled_resource_find=EXCLUDED.scaled_resource_find,cargo_capacity=EXCLUDED.cargo_capacity,metal=EXCLUDED.metal,crystal=EXCLUDED.crystal,deuterium=EXCLUDED.deuterium,resolved_at=clock_timestamp();
 ELSIF v_outcome='BLACK_HOLE' THEN
  PERFORM public.resolve_expedition_black_hole(p_fleet_id); RETURN 'BLACK_HOLE';
 ELSIF v_outcome='DARK_MATTER' THEN
  v_dm:=public.calculate_expedition_dark_matter_amount(p_fleet_id); UPDATE public.players SET dark_matter=COALESCE(dark_matter,0)+v_dm WHERE id=v_fleet.player_id; INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,dark_matter) VALUES(p_fleet_id,v_fleet.player_id,'DARK_MATTER',1,v_roll,v_weight_total,v_dm) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,dark_matter=EXCLUDED.dark_matter,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,resolved_at=clock_timestamp();
 ELSIF v_outcome='MERCHANT' THEN
  SELECT * INTO v_merchant FROM public.resolve_expedition_merchant(p_fleet_id);
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,merchant_resource,merchant_metal_rate,merchant_crystal_rate,merchant_deuterium_rate) VALUES(p_fleet_id,v_fleet.player_id,'MERCHANT',1,v_roll,v_weight_total,v_merchant.merchant_resource,v_merchant.metal_rate,v_merchant.crystal_rate,v_merchant.deuterium_rate) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,merchant_resource=EXCLUDED.merchant_resource,merchant_metal_rate=EXCLUDED.merchant_metal_rate,merchant_crystal_rate=EXCLUDED.merchant_crystal_rate,merchant_deuterium_rate=EXCLUDED.merchant_deuterium_rate,resolved_at=clock_timestamp();
 ELSIF v_outcome='DELAY' THEN
  v_delay_multiplier:=public.select_expedition_delay_multiplier(); v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier); INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds) VALUES(p_fleet_id,v_fleet.player_id,'DELAY',v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,resolved_at=clock_timestamp();
 ELSIF v_outcome='SPEEDUP' THEN
  v_speedup_percentage:=public.select_expedition_speedup_percentage(); v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage); v_return_seconds:=greatest(v_flight_seconds-v_speedup_seconds,1); INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,speedup_seconds) VALUES(p_fleet_id,v_fleet.player_id,'SPEEDUP',v_speedup_percentage,v_roll,v_weight_total,speedup_seconds) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp(); UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_return_seconds) WHERE id=p_fleet_id; RETURN 'SPEEDUP';
 ELSE
  INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total) ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,resolved_at=clock_timestamp();
 END IF;
 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_flight_seconds+v_hold_seconds)) WHERE id=p_fleet_id; RETURN v_outcome;
END;
$function$;