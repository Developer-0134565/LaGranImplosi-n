CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
 v_fleet RECORD; v_universe_id uuid; v_outcome text; v_roll numeric; v_weight_total numeric;
 v_actual_hold_seconds numeric:=3600; v_hold_seconds numeric:=0; v_delay_multiplier numeric:=1;
 v_speedup_percentage numeric:=0; v_speedup_seconds numeric:=0; v_flight_seconds numeric:=0; v_return_seconds numeric:=0;
 v_reward RECORD; v_ship_reward jsonb; v_ship_budget RECORD; v_ship_id text; v_ship_quantity bigint;
 v_battle RECORD; v_dm numeric:=0; v_merchant RECORD; v_item jsonb; v_existing_outcome text;
BEGIN
 SELECT fm.id,fm.player_id,fm.origin_planet_id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,
        COALESCE(fm.expedition_hold_seconds,3600) AS expedition_hold_seconds
 INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id; END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution',p_fleet_id; END IF;

 /* A resolved expedition is immutable. This prevents every reward/event from being rolled twice. */
 SELECT er.outcome INTO v_existing_outcome FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id FOR UPDATE;
 IF FOUND AND v_existing_outcome IS NOT NULL THEN
   RETURN v_existing_outcome;
 END IF;

 SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id=v_fleet.origin_planet_id;
 v_actual_hold_seconds:=GREATEST(v_fleet.expedition_hold_seconds,0);
 v_flight_seconds:=GREATEST(EXTRACT(EPOCH FROM(v_fleet.arrives_at-v_fleet.started_at)),1);
 SELECT es.weight_ships+es.weight_resources+es.weight_delay+es.weight_speedup+es.weight_nothing+es.weight_black_hole+es.weight_pirates+es.weight_aliens+es.weight_dark_matter+es.weight_merchant+es.weight_items
 INTO v_weight_total FROM public.expedition_settings es WHERE es.universe_id=v_universe_id;
 IF v_weight_total IS NULL OR v_weight_total<=0 THEN RAISE EXCEPTION 'Invalid expedition weights for universe %',v_universe_id; END IF;
 v_roll:=random()*v_weight_total;
 v_outcome:=public.select_expedition_outcome(v_universe_id,v_roll);

 IF v_outcome='PIRATES' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,resolved_at,event_type,random_roll,weight_total)
   VALUES(p_fleet_id,v_fleet.player_id,'PIRATES',v_battle.battle_id,v_battle.enemy_ships,v_battle.surviving_ships,clock_timestamp(),'PIRATES',v_roll,v_weight_total)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='ALIENS' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_aliens(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,battle_id,enemy_ships,ships,resolved_at,event_type,random_roll,weight_total)
   VALUES(p_fleet_id,v_fleet.player_id,'ALIENS',v_battle.battle_id,v_battle.enemy_ships,v_battle.survivors,clock_timestamp(),'ALIENS',v_roll,v_weight_total)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='SHIPS' THEN
   v_ship_reward:=public.prepare_expedition_ship_reward_multitype(p_fleet_id);
   SELECT reward_tier,reward_multiplier,max_ship_find,scaled_ship_find,ship_reward INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
   FOR v_ship_id,v_ship_quantity IN SELECT key,value::bigint FROM jsonb_each_text(v_ship_reward) LOOP
     IF v_ship_quantity>0 THEN
       INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) VALUES(p_fleet_id,v_ship_id,v_ship_quantity)
       ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity;
     END IF;
   END LOOP;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,ships)
   VALUES(p_fleet_id,v_fleet.player_id,'SHIPS',v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,v_ship_reward)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='RESOURCES' THEN
   SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
   UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,
       crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,
       deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium)
   VALUES(p_fleet_id,v_fleet.player_id,'RESOURCES',v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='BLACK_HOLE' THEN
   SELECT * INTO v_battle FROM public.resolve_expedition_black_hole(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,random_roll,weight_total,lost_ships,ships,loss_percentage,resolved_at,event_type)
   VALUES(p_fleet_id,v_fleet.player_id,'BLACK_HOLE',v_roll,v_weight_total,v_battle.lost_ships,v_battle.surviving_ships,v_battle.loss_percentage,clock_timestamp(),'BLACK_HOLE')
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='DARK_MATTER' THEN
   v_dm:=public.calculate_expedition_dark_matter_amount(p_fleet_id);
   UPDATE public.players SET dark_matter=COALESCE(dark_matter,0)+v_dm WHERE id=v_fleet.player_id;
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,dark_matter)
   VALUES(p_fleet_id,v_fleet.player_id,'DARK_MATTER',1,v_roll,v_weight_total,v_dm)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='MERCHANT' THEN
   SELECT * INTO v_merchant FROM public.resolve_expedition_merchant(p_fleet_id);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,merchant_resource,merchant_metal_rate,merchant_crystal_rate,merchant_deuterium_rate)
   VALUES(p_fleet_id,v_fleet.player_id,'MERCHANT',1,v_roll,v_weight_total,v_merchant.merchant_resource,v_merchant.metal_rate,v_merchant.crystal_rate,v_merchant.deuterium_rate)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='ITEMS' THEN
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,resolved_at,event_type)
   VALUES(p_fleet_id,v_fleet.player_id,'ITEMS',1,v_roll,v_weight_total,clock_timestamp(),'ITEMS')
   ON CONFLICT(fleet_id) DO NOTHING;
   v_item:=public.resolve_expedition_item(p_fleet_id);
 ELSIF v_outcome='DELAY' THEN
   v_delay_multiplier:=public.select_expedition_delay_multiplier();
   v_hold_seconds:=public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds)
   VALUES(p_fleet_id,v_fleet.player_id,'DELAY',v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds)
   ON CONFLICT(fleet_id) DO NOTHING;
 ELSIF v_outcome='SPEEDUP' THEN
   v_speedup_percentage:=public.select_expedition_speedup_percentage();
   v_speedup_seconds:=public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage);
   v_return_seconds:=GREATEST(v_flight_seconds-v_speedup_seconds,1);
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,speedup_seconds)
   VALUES(p_fleet_id,v_fleet.player_id,'SPEEDUP',v_speedup_percentage,v_roll,v_weight_total,v_speedup_seconds)
   ON CONFLICT(fleet_id) DO NOTHING;
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_return_seconds)) WHERE id=p_fleet_id;
   RETURN 'SPEEDUP';
 ELSE
   INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total)
   VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total)
   ON CONFLICT(fleet_id) DO NOTHING;
 END IF;

 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>(v_actual_hold_seconds+v_flight_seconds+v_hold_seconds)) WHERE id=p_fleet_id;
 RETURN v_outcome;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_pirates(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid, battle_result text, enemy_ships jsonb, surviving_ships jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE f RECORD; v_battle uuid; pid uuid; tier integer; strength numeric; fixed_id text; fixed_qty integer; x RECORD; n integer; enemy jsonb; surviving jsonb; v_combat RECORD;
BEGIN
 SELECT fm.* INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
 IF EXISTS(SELECT 1 FROM public.expedition_results WHERE fleet_id=p_fleet_id) THEN
   SELECT er.battle_id,er.outcome,COALESCE(er.enemy_ships,'{}'),COALESCE(er.ships,'{}') INTO battle_id,battle_result,enemy_ships,surviving_ships FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id; RETURN NEXT; RETURN;
 END IF;
 pid:=f.player_id;
 IF EXISTS(SELECT 1 FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='deathstar' AND quantity>0) THEN RAISE EXCEPTION 'Deathstar expeditions cannot receive pirate combat'; END IF;
 tier:=floor(random()*100)+1;
 IF tier<=89 THEN strength:=0.27+random()*0.06; fixed_id:='light_fighter'; fixed_qty:=5; ELSIF tier<=99 THEN strength:=0.45+random()*0.10; fixed_id:='cruiser'; fixed_qty:=3; ELSE strength:=0.72+random()*0.16; fixed_id:='battleship'; fixed_qty:=2; END IF;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at) VALUES(p_fleet_id,pid,f.origin_planet_id,0,0,0,0,0,0,0,0,clock_timestamp()) RETURNING id INTO v_battle;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP; END LOOP;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 AND fms.ship_id NOT IN('recycler','colony_ship','deathstar','espionage_probe') LOOP FOR n IN 1..floor(x.quantity*strength) LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP; END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x.attack,x.shield,x.hull FROM public.ship_definitions sd WHERE sd.id=fixed_id;
 FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',fixed_id,100000+n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP;
 UPDATE public.combat_battles cb SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER') WHERE cb.id=v_battle;
 SELECT * INTO v_combat FROM public.run_expedition_combat(v_battle);
 UPDATE public.fleet_movement_ships fms SET quantity=q.quantity FROM (SELECT fms2.ship_id,count(*)::bigint quantity FROM public.fleet_movement_ships fms2 JOIN public.combat_individual_units ciu ON ciu.battle_id=v_battle AND ciu.side='ATTACKER' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id GROUP BY fms2.ship_id) q WHERE fms.fleet_id=p_fleet_id AND fms.ship_id=q.ship_id;
 DELETE FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='ATTACKER' AND ciu.unit_id=fms.ship_id AND ciu.alive);
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='DEFENDER' GROUP BY ciu.unit_id) q;
 SELECT COALESCE(jsonb_object_agg(fms.ship_id,fms.quantity),'{}') INTO surviving FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id;
 battle_id:=v_battle;battle_result:=v_combat.battle_result;enemy_ships:=enemy;surviving_ships:=surviving;RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_aliens(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid, result text, enemy_ships jsonb, survivors jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE f public.fleet_movements%ROWTYPE; b uuid; pid uuid; total bigint:=0; adapted bigint; fixed_id text; fixed_qty int; roll numeric; strength numeric; tech int; alien_tech int; enemy jsonb:='{}'; surv jsonb:='{}'; res text; x record; n int; v_combat RECORD;
BEGIN
 SELECT * INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
 SELECT er.battle_id,er.outcome,COALESCE(er.enemy_ships,'{}'),COALESCE(er.ships,'{}') INTO battle_id,result,enemy_ships,survivors FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id AND er.outcome='ALIENS';
 IF FOUND THEN RETURN NEXT; RETURN; END IF;
 IF f.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition fleet % must be ARRIVED',p_fleet_id; END IF;
 pid:=f.player_id;
 SELECT COALESCE(MAX(pr.level),0) INTO tech FROM public.player_research pr JOIN public.research_definitions rd ON rd.id=pr.research_id WHERE pr.player_id=pid AND rd.id IN('weapons','shielding','armour');
 alien_tech:=tech+3;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at,created_at) VALUES(p_fleet_id,pid,NULL,0,0,0,0,0,0,0,0,clock_timestamp(),clock_timestamp()) RETURNING id INTO b;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP; total:=total+x.quantity; END LOOP;
 roll:=random()*100; IF roll<89 THEN strength:=0.34+random()*0.12;fixed_id:='heavy_fighter';fixed_qty:=5; ELSIF roll<99 THEN strength:=0.54+random()*0.12;fixed_id:='battlecruiser';fixed_qty:=3; ELSE strength:=0.81+random()*0.18;fixed_id:='destroyer';fixed_qty:=2; END IF;
 adapted:=greatest(1,floor(total*strength)); SELECT fms.ship_id,sd.attack,sd.shield,sd.hull INTO x FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id ORDER BY fms.quantity DESC,fms.ship_id LIMIT 1;
 FOR n IN 1..adapted LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'DEFENDER','SHIP',x.ship_id,n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true); END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x FROM public.ship_definitions sd WHERE sd.id=fixed_id;
 FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'DEFENDER','SHIP',fixed_id,100000+n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true); END LOOP;
 UPDATE public.combat_battles cb SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER') WHERE cb.id=b;
 SELECT * INTO v_combat FROM public.run_expedition_combat(b);
 DELETE FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.unit_id=fms.ship_id AND ciu.alive);
 UPDATE public.fleet_movement_ships fms SET quantity=q.quantity FROM (SELECT fms2.ship_id,count(*)::bigint quantity FROM public.fleet_movement_ships fms2 JOIN public.combat_individual_units ciu ON ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id GROUP BY fms2.ship_id) q WHERE fms.fleet_id=p_fleet_id AND fms.ship_id=q.ship_id;
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='DEFENDER' GROUP BY ciu.unit_id)q;
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO surv FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.alive GROUP BY ciu.unit_id)q;
 INSERT INTO public.expedition_results(fleet_id,player_id,outcome,ships,battle_id,resolved_at,enemy_ships,event_type) VALUES(p_fleet_id,pid,'ALIENS',surv,b,now(),enemy,'ALIENS') ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,battle_id=EXCLUDED.battle_id,enemy_ships=EXCLUDED.enemy_ships,event_type='ALIENS',resolved_at=EXCLUDED.resolved_at,ships=EXCLUDED.ships;
 SELECT CASE WHEN cb.attacker_win THEN 'ATTACKER_WIN' WHEN cb.defender_win THEN 'DEFENDER_WIN' ELSE 'DRAW' END INTO res FROM public.combat_battles cb WHERE cb.id=b;
 battle_id:=b;result:=res;enemy_ships:=enemy;survivors:=surv;RETURN NEXT;
END;
$function$;