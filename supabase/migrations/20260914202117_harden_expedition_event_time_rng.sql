CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_rate_at(p_universe_id uuid, p_at timestamptz)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_created_at timestamptz;
    v_age_days numeric;
BEGIN
    SELECT created_at INTO v_created_at
    FROM public.universes
    WHERE id = p_universe_id;

    IF v_created_at IS NULL THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    v_age_days := GREATEST(0, EXTRACT(EPOCH FROM (p_at - v_created_at)) / 86400);

    RETURN CASE
        WHEN v_age_days < 7 THEN 1 + (v_age_days / 7) * 4
        WHEN v_age_days < 14 THEN 5 + ((v_age_days - 7) / 7) * 5
        WHEN v_age_days < 30 THEN 10 + ((v_age_days - 14) / 16) * 15
        WHEN v_age_days < 45 THEN 25 + ((v_age_days - 30) / 15) * 15
        WHEN v_age_days < 60 THEN 40 + ((v_age_days - 45) / 15) * 20
        WHEN v_age_days < 90 THEN 60 + ((v_age_days - 60) / 30) * 40
        ELSE 100
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_rate(p_universe_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.calculate_universe_evolution_rate_at(p_universe_id, now());
$function$;

CREATE OR REPLACE FUNCTION public.expedition_event_random(p_fleet_id uuid, p_stream text, p_index integer DEFAULT 0)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_arrives_at timestamptz;
    v_hash int;
    v_unsigned numeric;
BEGIN
    SELECT arrives_at INTO v_arrives_at
    FROM public.fleet_movements
    WHERE id = p_fleet_id AND mission_type = 'EXPEDITION';

    IF v_arrives_at IS NULL THEN
        RAISE EXCEPTION 'Expedition fleet % not found or has no arrives_at', p_fleet_id;
    END IF;

    v_hash := ('x' || substr(md5(p_fleet_id::text || '|' || v_arrives_at::text || '|' || COALESCE(p_stream,'') || '|' || p_index::text), 1, 8))::bit(32)::int;
    v_unsigned := CASE WHEN v_hash < 0 THEN v_hash::numeric + 4294967296 ELSE v_hash::numeric END;
    RETURN v_unsigned / 4294967296.0;
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_outcome(p_universe_id uuid, p_roll numeric DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_roll numeric;
    v_total numeric;
    v_outcome text;
BEGIN
    SELECT weight_ships + weight_resources + weight_delay + weight_speedup + weight_nothing + weight_black_hole + weight_pirates + weight_aliens + weight_dark_matter + weight_merchant + weight_items
    INTO v_total
    FROM public.expedition_settings WHERE universe_id = p_universe_id;
    IF v_total IS NULL OR v_total <= 0 THEN RAISE EXCEPTION 'Invalid expedition outcome weights'; END IF;
    v_roll := COALESCE(p_roll, random() * v_total);
    IF v_roll < 0 OR v_roll >= v_total THEN RAISE EXCEPTION 'Expedition roll % outside [0, %)', v_roll, v_total; END IF;
    SELECT outcome INTO v_outcome
    FROM (
        SELECT outcome, sum(weight) OVER (ORDER BY sort_order) AS upper_bound
        FROM (VALUES
            (1,'SHIPS',(SELECT weight_ships FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (2,'RESOURCES',(SELECT weight_resources FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (3,'DELAY',(SELECT weight_delay FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (4,'SPEEDUP',(SELECT weight_speedup FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (5,'NOTHING',(SELECT weight_nothing FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (6,'BLACK_HOLE',(SELECT weight_black_hole FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (7,'PIRATES',(SELECT weight_pirates FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (8,'ALIENS',(SELECT weight_aliens FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (9,'DARK_MATTER',(SELECT weight_dark_matter FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (10,'MERCHANT',(SELECT weight_merchant FROM public.expedition_settings WHERE universe_id=p_universe_id)),
            (11,'ITEMS',(SELECT weight_items FROM public.expedition_settings WHERE universe_id=p_universe_id))
        ) AS x(sort_order,outcome,weight)
    ) weighted
    WHERE v_roll < upper_bound
    ORDER BY upper_bound LIMIT 1;
    RETURN v_outcome;
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_reward_variant(p_fleet_id uuid)
RETURNS TABLE(reward_tier text, reward_multiplier numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_roll numeric := public.expedition_event_random(p_fleet_id,'reward_variant_tier');
    v_bonus numeric;
BEGIN
    IF v_roll < 0.89 THEN
        reward_tier := 'NORMAL'; reward_multiplier := 1;
    ELSIF v_roll < 0.99 THEN
        v_bonus := public.expedition_event_random(p_fleet_id,'reward_variant_rare_multiplier');
        reward_tier := 'RARE'; reward_multiplier := floor(v_bonus * 2) + 2;
    ELSE
        v_bonus := public.expedition_event_random(p_fleet_id,'reward_variant_exceptional_multiplier');
        reward_tier := 'EXCEPTIONAL'; reward_multiplier := floor(v_bonus * 6) + 5;
    END IF;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_reward_variant()
RETURNS TABLE(reward_tier text, reward_multiplier numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_roll numeric := random()*100;
BEGIN
    IF v_roll < 89 THEN reward_tier:='NORMAL'; reward_multiplier:=1;
    ELSIF v_roll < 99 THEN reward_tier:='RARE'; reward_multiplier:=floor(random()*2)+2;
    ELSE reward_tier:='EXCEPTIONAL'; reward_multiplier:=floor(random()*6)+5;
    END IF;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_expedition_reward_budget(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_universe_id uuid; v_tier text; v_multiplier numeric; v_points numeric; v_resource_cap numeric; v_cargo_capacity numeric; v_budget_id uuid;
BEGIN
    SELECT id INTO v_budget_id FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id;
    IF FOUND THEN RETURN v_budget_id; END IF;
    SELECT p.universe_id INTO v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
    SELECT x.reward_tier,x.reward_multiplier INTO v_tier,v_multiplier FROM public.select_expedition_reward_variant(p_fleet_id) x;
    v_points:=public.calculate_expedition_points(p_fleet_id);
    v_resource_cap:=public.calculate_expedition_resource_cap(v_universe_id);
    SELECT COALESCE(SUM(fms.quantity*sd.cargo_capacity),0) INTO v_cargo_capacity FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id;
    INSERT INTO public.expedition_reward_budgets(fleet_id,reward_tier,reward_multiplier,expedition_points,resource_cap,cargo_capacity)
    VALUES(p_fleet_id,v_tier,v_multiplier,v_points,v_resource_cap,v_cargo_capacity) RETURNING id INTO v_budget_id;
    RETURN v_budget_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_base_resource_find(p_fleet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_universe_id uuid; v_resource_cap numeric; v_min numeric; v_base numeric;
BEGIN
    SELECT p.universe_id INTO v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
    v_resource_cap:=public.calculate_expedition_resource_cap(v_universe_id);
    v_min:=GREATEST(1,floor(v_resource_cap*0.10));
    v_base:=floor(public.expedition_event_random(p_fleet_id,'resource_base')*(v_resource_cap-v_min+1))+v_min;
    RETURN v_base;
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_resource_type(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_roll numeric:=public.expedition_event_random(p_fleet_id,'resource_type');
BEGIN
    IF v_roll<0.50 THEN RETURN 'METAL'; ELSIF v_roll<0.8333333333333333 THEN RETURN 'CRYSTAL'; ELSE RETURN 'DEUTERIUM'; END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_resource_type()
RETURNS text
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_roll numeric:=random();
BEGIN
    IF v_roll<0.50 THEN RETURN 'METAL'; ELSIF v_roll<0.8333333333333333 THEN RETURN 'CRYSTAL'; ELSE RETURN 'DEUTERIUM'; END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_ship_reward_budget(p_fleet_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_universe_id uuid; v_resource_cap numeric; v_min numeric;
BEGIN
    SELECT p.universe_id INTO v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet not found: %',p_fleet_id; END IF;
    v_resource_cap:=public.calculate_expedition_resource_cap(v_universe_id); v_min:=GREATEST(1,floor(v_resource_cap*0.10));
    RETURN floor(public.expedition_event_random(p_fleet_id,'ship_budget')*(v_resource_cap-v_min+1))+v_min;
END;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_expedition_resource_reward(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid,reward_tier text,reward_multiplier numeric,expedition_points numeric,base_resource_find numeric,max_resource_find numeric,scaled_resource_find numeric,cargo_capacity numeric,resource_type text,final_resource_amount numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_budget public.expedition_reward_budgets%ROWTYPE; v_base numeric; v_class_multiplier numeric; v_pathfinder_multiplier numeric; v_universe_multiplier numeric; v_max_find numeric; v_scaled numeric; v_resource_type text; v_final numeric;
BEGIN
    SELECT * INTO v_budget FROM public.expedition_reward_budgets erb WHERE erb.fleet_id=p_fleet_id FOR UPDATE;
    IF NOT FOUND THEN PERFORM public.create_expedition_reward_budget(p_fleet_id); SELECT * INTO v_budget FROM public.expedition_reward_budgets erb WHERE erb.fleet_id=p_fleet_id FOR UPDATE; END IF;
    IF v_budget.base_resource_find IS NOT NULL AND v_budget.max_resource_find IS NOT NULL AND v_budget.scaled_resource_find IS NOT NULL AND v_budget.resource_type IS NOT NULL AND v_budget.final_resource_amount IS NOT NULL THEN
        fleet_id:=v_budget.fleet_id; reward_tier:=v_budget.reward_tier; reward_multiplier:=v_budget.reward_multiplier; expedition_points:=v_budget.expedition_points; base_resource_find:=v_budget.base_resource_find; max_resource_find:=v_budget.max_resource_find; scaled_resource_find:=v_budget.scaled_resource_find; cargo_capacity:=v_budget.cargo_capacity; resource_type:=v_budget.resource_type; final_resource_amount:=v_budget.final_resource_amount; RETURN NEXT; RETURN;
    END IF;
    v_base:=public.calculate_expedition_base_resource_find(p_fleet_id);
    v_class_multiplier:=public.calculate_expedition_class_resource_multiplier(p_fleet_id);
    v_pathfinder_multiplier:=public.calculate_expedition_pathfinder_multiplier(p_fleet_id);
    v_universe_multiplier:=public.calculate_expedition_resource_multiplier(p_fleet_id);
    v_max_find:=floor(v_base*v_class_multiplier*v_pathfinder_multiplier*v_universe_multiplier);
    v_scaled:=floor(v_max_find*v_budget.reward_multiplier);
    v_resource_type:=public.select_expedition_resource_type(p_fleet_id);
    v_final:=public.calculate_expedition_resource_amount_for_type(v_max_find,v_budget.reward_multiplier,v_budget.cargo_capacity,v_resource_type);
    UPDATE public.expedition_reward_budgets SET base_resource_find=v_base,max_resource_find=v_max_find,scaled_resource_find=v_scaled,resource_type=v_resource_type,final_resource_amount=v_final WHERE fleet_id=p_fleet_id;
    fleet_id:=p_fleet_id; reward_tier:=v_budget.reward_tier; reward_multiplier:=v_budget.reward_multiplier; expedition_points:=v_budget.expedition_points; base_resource_find:=v_base; max_resource_find:=v_max_find; scaled_resource_find:=v_scaled; cargo_capacity:=v_budget.cargo_capacity; resource_type:=v_resource_type; final_resource_amount:=v_final; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_dark_matter_amount(p_fleet_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_universe_id uuid;v_player_id uuid;v_planet_id uuid;v_multiplier numeric:=1;v_class_multiplier numeric:=1;v_tier_multiplier numeric:=1;v_item_bonus numeric:=0;v_lf_bonus numeric:=0;v_base numeric;
BEGIN
 SELECT fm.player_id,fm.origin_planet_id,p.universe_id INTO v_player_id,v_planet_id,v_universe_id FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
 SELECT COALESCE(reward_multiplier_dark_matter,1) INTO v_multiplier FROM public.expedition_settings WHERE universe_id=v_universe_id;
 SELECT COALESCE(dark_matter_multiplier,1) INTO v_class_multiplier FROM public.player_expedition_modifiers WHERE player_id=v_player_id;
 SELECT COALESCE(reward_multiplier,1) INTO v_tier_multiplier FROM public.expedition_results WHERE fleet_id=p_fleet_id;
 v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,v_planet_id,'expedition_reward_percent');
 v_lf_bonus:=public.get_active_lifeform_research_effect(v_player_id,'expedition_dm_percent');
 v_base:=floor(public.expedition_event_random(p_fleet_id,'dark_matter_amount')*81)+20;
 RETURN greatest(20,round(v_base*COALESCE(v_multiplier,1)*COALESCE(v_class_multiplier,1)*COALESCE(v_tier_multiplier,1)*(1+(v_item_bonus+v_lf_bonus)/100)));
END;$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_delay_multiplier(p_fleet_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$ SELECT CASE WHEN public.expedition_event_random(p_fleet_id,'delay_multiplier')<0.89 THEN 2 WHEN public.expedition_event_random(p_fleet_id,'delay_multiplier')<0.99 THEN 3 ELSE 5 END $function$;

CREATE OR REPLACE FUNCTION public.select_expedition_speedup_percentage(p_fleet_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$ SELECT floor(public.expedition_event_random(p_fleet_id,'speedup_percentage')*6)+5 $function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_delay_seconds(p_fleet_id uuid,p_multiplier numeric)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_universe_id uuid;v_fleet_speed numeric;v_evolution numeric;v_fleet_rate numeric;v_holding_seconds numeric:=3600;v_additional_delay numeric;v_arrives_at timestamptz;
BEGIN
 IF p_multiplier NOT IN(2,3,5) THEN RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5';END IF;
 SELECT p.universe_id,fm.arrives_at INTO v_universe_id,v_arrives_at FROM public.fleet_movements fm JOIN public.planets p ON p.id=fm.origin_planet_id WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION';
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
 SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE u.id=v_universe_id;
 IF v_fleet_speed IS NULL OR v_fleet_speed<=0 THEN RAISE EXCEPTION 'Invalid universe fleet speed for expedition %',p_fleet_id;END IF;
 v_evolution:=public.calculate_universe_evolution_rate_at(v_universe_id,v_arrives_at);
 v_fleet_rate:=v_fleet_speed*power(v_evolution,1.0/3.0);
 v_additional_delay:=floor((v_holding_seconds*p_multiplier)/v_fleet_rate);
 RETURN greatest(v_additional_delay,1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_fleet RECORD;v_universe_id uuid;v_outcome text;v_roll numeric;v_weight_total numeric;v_actual_hold_seconds numeric:=3600;v_hold_seconds numeric:=0;v_delay_multiplier numeric:=1;v_speedup_percentage numeric:=0;v_speedup_seconds numeric:=0;v_flight_seconds numeric:=0;v_return_seconds numeric:=0;v_reward RECORD;v_ship_reward jsonb;v_ship_budget RECORD;v_ship_id text;v_ship_quantity bigint;v_battle RECORD;v_dm numeric:=0;v_merchant RECORD;v_item jsonb;v_existing_outcome text;
BEGIN
 SELECT fm.id,fm.player_id,fm.origin_planet_id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,COALESCE(fm.expedition_hold_seconds,3600) AS expedition_hold_seconds INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id;END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id;END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution',p_fleet_id;END IF;
 SELECT er.outcome INTO v_existing_outcome FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id FOR UPDATE;
 IF FOUND AND v_existing_outcome IS NOT NULL THEN RETURN v_existing_outcome;END IF;
 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=v_fleet.origin_planet_id;
 v_actual_hold_seconds:=GREATEST(v_fleet.expedition_hold_seconds,0);v_flight_seconds:=GREATEST(EXTRACT(EPOCH FROM(v_fleet.arrives_at-v_fleet.started_at)),1);
 SELECT es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing+es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter+es.weight_merchant+es.weight_items INTO v_weight_total FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
 IF v_weight_total IS NULL OR v_weight_total<=0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %',v_universe_id;END IF;
 v_roll:=public.expedition_event_random(p_fleet_id,'outcome')*v_weight_total;v_outcome:=public.select_expedition_outcome(v_universe_id,v_roll);
 IF v_outcome='PIRATES' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,resolved_at,event_type,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,'PIRATES',v_battle.battle_id,v_battle.enemy_ships,v_battle.surviving_ships,v_fleet.arrives_at,'PIRATES',v_roll,v_weight_total) ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='ALIENS' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,resolved_at,event_type,random_roll,weight_total) VALUES(p_fleet_id,v_fleet.player_id,'ALIENS',v_battle.battle_id,v_battle.enemy_ships,v_battle.survivors,v_fleet.arrives_at,'ALIENS',v_roll,v_weight_total) ON CONFLICT(fleet_id) DO NOTHING;
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