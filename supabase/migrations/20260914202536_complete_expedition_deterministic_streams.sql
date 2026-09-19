CREATE OR REPLACE FUNCTION public.prepare_expedition_ship_reward_multitype(p_fleet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_budget public.expedition_reward_budgets%ROWTYPE;v_candidate_count integer;v_pick_count integer;v_index integer;v_total_weight numeric:=0;v_weight numeric;v_allocated numeric;v_remaining numeric;v_ship_id text;v_ship_cost numeric;v_quantity bigint;v_result jsonb:='{}'::jsonb;v_candidates text[];v_weights numeric[];
BEGIN
 PERFORM public.create_expedition_reward_budget(p_fleet_id);
 SELECT * INTO v_budget FROM public.expedition_reward_budgets WHERE fleet_id=p_fleet_id FOR UPDATE;
 IF v_budget.ship_reward<>'{}'::jsonb AND v_budget.scaled_ship_find>0 THEN RETURN v_budget.ship_reward;END IF;
 v_budget.max_ship_find:=public.calculate_expedition_max_ship_find(p_fleet_id);v_budget.scaled_ship_find:=v_budget.max_ship_find;v_remaining:=v_budget.scaled_ship_find;
 SELECT array_agg(ship_id ORDER BY ship_id) INTO v_candidates FROM public.get_expedition_ship_candidates(p_fleet_id);
 IF v_candidates IS NULL OR array_length(v_candidates,1) IS NULL THEN UPDATE public.expedition_reward_budgets SET max_ship_find=v_budget.max_ship_find,scaled_ship_find=v_budget.scaled_ship_find,ship_reward='{}'::jsonb WHERE fleet_id=p_fleet_id;RETURN '{}'::jsonb;END IF;
 v_candidate_count:=array_length(v_candidates,1);
 v_pick_count:=LEAST(v_candidate_count,floor(public.expedition_event_random(p_fleet_id,'ship_pick_count')*6)::integer+1);
 v_weights:=ARRAY[]::numeric[];
 FOR v_index IN 1..v_pick_count LOOP v_weight:=0.25+public.expedition_event_random(p_fleet_id,'ship_weight',v_index)*1.50;v_weights:=array_append(v_weights,v_weight);v_total_weight:=v_total_weight+v_weight;END LOOP;
 FOR v_index IN 1..v_pick_count LOOP
   v_ship_id:=v_candidates[v_index];SELECT public.calculate_expedition_ship_cost(v_ship_id) INTO v_ship_cost;
   IF v_index=v_pick_count THEN v_allocated:=v_remaining;ELSE v_allocated:=LEAST(floor(v_budget.scaled_ship_find*(v_weights[v_index]/v_total_weight)),v_remaining);END IF;
   v_quantity:=floor(v_allocated/v_ship_cost)::bigint;
   IF v_quantity>0 THEN v_result:=jsonb_set(v_result,ARRAY[v_ship_id],to_jsonb(v_quantity),true);END IF;
   v_remaining:=GREATEST(v_remaining-v_allocated,0);
 END LOOP;
 UPDATE public.expedition_reward_budgets SET max_ship_find=v_budget.max_ship_find,scaled_ship_find=v_budget.scaled_ship_find,ship_reward=v_result WHERE fleet_id=p_fleet_id;
 RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_black_hole(p_fleet_id uuid)
RETURNS TABLE(lost_ships jsonb,surviving_ships jsonb,loss_percentage numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_loss_percentage numeric;v_total bigint:=0;v_loss_target bigint:=0;v_lost bigint:=0;v_ship record;v_loss_qty bigint;v_remaining bigint;v_survivors jsonb:='{}'::jsonb;v_lost_json jsonb:='{}'::jsonb;
BEGIN
 v_loss_percentage:=round((30+public.expedition_event_random(p_fleet_id,'black_hole_loss_percentage')*30)::numeric,2);
 SELECT COALESCE(sum(quantity),0) INTO v_total FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND quantity>0;
 IF v_total<=0 THEN RETURN QUERY SELECT '{}'::jsonb,'{}'::jsonb,0::numeric;RETURN;END IF;
 v_loss_target:=least(v_total-1,greatest(1,round(v_total*v_loss_percentage/100))::bigint);v_remaining:=v_loss_target;
 FOR v_ship IN SELECT fleet_id,ship_id,quantity FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND quantity>0 ORDER BY quantity DESC,ship_id LOOP
  EXIT WHEN v_remaining<=0;
  v_loss_qty:=least(v_ship.quantity,greatest(0,round(v_loss_target*v_ship.quantity::numeric/v_total)::bigint));
  IF v_remaining>0 AND v_ship.quantity>v_loss_qty THEN v_loss_qty:=least(v_ship.quantity-1,v_remaining);END IF;
  IF v_loss_qty>0 THEN UPDATE public.fleet_movement_ships SET quantity=quantity-v_loss_qty WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id;DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id AND quantity<=0;v_lost_json:=jsonb_set(v_lost_json,ARRAY[v_ship.ship_id],to_jsonb(v_loss_qty),true);v_lost:=v_lost+v_loss_qty;v_remaining:=v_remaining-v_loss_qty;END IF;
 END LOOP;
 SELECT COALESCE(jsonb_object_agg(ship_id,quantity),'{}'::jsonb) INTO v_survivors FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND quantity>0;
 v_loss_percentage:=round((v_lost::numeric/v_total::numeric)*100,2);
 RETURN QUERY SELECT v_lost_json,v_survivors,v_loss_percentage;
END;$function$;

CREATE OR REPLACE FUNCTION public.select_expedition_merchant_offer(p_fleet_id uuid)
RETURNS TABLE(resource text,metal_rate numeric,crystal_rate numeric,deuterium_rate numeric) LANGUAGE plpgsql STABLE SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_resource_index integer;v_quality numeric;
BEGIN
 v_resource_index:=floor(public.expedition_event_random(p_fleet_id,'merchant_resource')*3)::integer+1;
 v_quality:=round((2.5+public.expedition_event_random(p_fleet_id,'merchant_quality')*0.5)::numeric,3);
 resource:=(ARRAY['METAL','CRYSTAL','DEUTERIUM'])[v_resource_index];metal_rate:=v_quality;crystal_rate:=greatest(1.5,round((v_quality-1)::numeric,3));deuterium_rate:=1;RETURN NEXT;
END;$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_merchant(p_fleet_id uuid)
RETURNS TABLE(merchant_resource text,metal_rate numeric,crystal_rate numeric,deuterium_rate numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_fleet record;v_offer record;v_existing record;v_has_existing boolean:=false;
BEGIN
 SELECT fm.id,fm.player_id,fm.mission_type,fm.status INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found',p_fleet_id;END IF;
 IF v_fleet.mission_type<>'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION',p_fleet_id;END IF;
 SELECT * INTO v_existing FROM public.player_expedition_merchants WHERE player_id=v_fleet.player_id AND active=true FOR UPDATE;v_has_existing:=FOUND;
 SELECT * INTO v_offer FROM public.select_expedition_merchant_offer(p_fleet_id);
 IF v_has_existing THEN
  INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active) VALUES(v_fleet.player_id,v_existing.resource,GREATEST(v_existing.metal_rate,v_offer.metal_rate),GREATEST(v_existing.crystal_rate,v_offer.crystal_rate),1,'EXPEDITION',true) ON CONFLICT(player_id) DO UPDATE SET resource=public.player_expedition_merchants.resource,metal_rate=LEAST(3,GREATEST(public.player_expedition_merchants.metal_rate,EXCLUDED.metal_rate)),crystal_rate=LEAST(2,GREATEST(public.player_expedition_merchants.crystal_rate,EXCLUDED.crystal_rate)),deuterium_rate=1,active=true,source='EXPEDITION',updated_at=now();
 ELSE
  INSERT INTO public.player_expedition_merchants(player_id,resource,metal_rate,crystal_rate,deuterium_rate,source,active) VALUES(v_fleet.player_id,v_offer.resource,v_offer.metal_rate,v_offer.crystal_rate,1,'EXPEDITION',true) ON CONFLICT(player_id) DO UPDATE SET resource=EXCLUDED.resource,metal_rate=EXCLUDED.metal_rate,crystal_rate=EXCLUDED.crystal_rate,deuterium_rate=1,active=true,source='EXPEDITION',updated_at=now();
 END IF;
 RETURN QUERY SELECT pem.resource,pem.metal_rate,pem.crystal_rate,pem.deuterium_rate FROM public.player_expedition_merchants pem WHERE pem.player_id=v_fleet.player_id;
END;$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_pirates(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid,battle_result text,enemy_ships jsonb,surviving_ships jsonb) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE f RECORD;v_battle uuid;pid uuid;tier integer;strength numeric;fixed_id text;fixed_qty integer;x RECORD;n integer;enemy jsonb;surviving jsonb;v_combat RECORD;
BEGIN
 SELECT fm.* INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
 IF EXISTS(SELECT 1 FROM public.expedition_results WHERE fleet_id=p_fleet_id) THEN SELECT er.battle_id,er.outcome,COALESCE(er.enemy_ships,'{}'),COALESCE(er.ships,'{}') INTO battle_id,battle_result,enemy_ships,surviving_ships FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id;RETURN NEXT;RETURN;END IF;
 pid:=f.player_id;if EXISTS(SELECT 1 FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='deathstar' AND quantity>0) THEN RAISE EXCEPTION 'Deathstar expeditions cannot receive pirate combat';END IF;
 tier:=floor(public.expedition_event_random(p_fleet_id,'pirate_tier')*100)+1;
 IF tier<=89 THEN strength:=0.27+public.expedition_event_random(p_fleet_id,'pirate_strength')*0.06;fixed_id:='light_fighter';fixed_qty:=5;ELSIF tier<=99 THEN strength:=0.45+public.expedition_event_random(p_fleet_id,'pirate_strength')*0.10;fixed_id:='cruiser';fixed_qty:=3;ELSE strength:=0.72+public.expedition_event_random(p_fleet_id,'pirate_strength')*0.16;fixed_id:='battleship';fixed_qty:=2;END IF;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at) VALUES(p_fleet_id,pid,f.origin_planet_id,0,0,0,0,0,0,0,0,f.arrives_at) RETURNING id INTO v_battle;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);END LOOP;END LOOP;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 AND fms.ship_id NOT IN('recycler','colony_ship','deathstar','espionage_probe') LOOP FOR n IN 1..floor(x.quantity*strength) LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);END LOOP;END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x.attack,x.shield,x.hull FROM public.ship_definitions sd WHERE sd.id=fixed_id;FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',fixed_id,100000+n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);END LOOP;
 UPDATE public.combat_battles cb SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER') WHERE id=v_battle;
 SELECT * INTO v_combat FROM public.run_expedition_combat(v_battle);
 UPDATE public.fleet_movement_ships fms SET quantity=q.quantity FROM (SELECT fms2.ship_id,count(*)::bigint quantity FROM public.fleet_movement_ships fms2 JOIN public.combat_individual_units ciu ON ciu.battle_id=v_battle AND ciu.side='ATTACKER' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id GROUP BY fms2.ship_id) q WHERE fms.fleet_id=p_fleet_id AND fms.ship_id=q.ship_id;
 DELETE FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='ATTACKER' AND ciu.unit_id=fms.ship_id AND ciu.alive);
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='DEFENDER' GROUP BY ciu.unit_id)q;
 SELECT COALESCE(jsonb_object_agg(fms.ship_id,fms.quantity),'{}') INTO surviving FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id;
 battle_id:=v_battle;battle_result:=v_combat.battle_result;enemy_ships:=enemy;surviving_ships:=surviving;RETURN NEXT;
END;$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_aliens(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid,result text,enemy_ships jsonb,survivors jsonb) LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE f public.fleet_movements%ROWTYPE;b uuid;pid uuid;total bigint:=0;adapted bigint;fixed_id text;fixed_qty int;roll numeric;strength numeric;tech int;alien_tech int;x record;n int;enemy jsonb:='{}';surv jsonb:='{}';res text;v_combat RECORD;
BEGIN
 SELECT * INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id;END IF;
 SELECT er.battle_id,er.outcome,COALESCE(er.enemy_ships,'{}'),COALESCE(er.ships,'{}') INTO battle_id,result,enemy_ships,survivors FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id AND er.outcome='ALIENS';IF FOUND THEN RETURN NEXT;RETURN;END IF;
 IF f.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition fleet % must be ARRIVED',p_fleet_id;END IF;pid:=f.player_id;
 SELECT COALESCE(MAX(pr.level),0) INTO tech FROM public.player_research pr JOIN public.research_definitions rd ON rd.id=pr.research_id WHERE pr.player_id=pid AND rd.id IN('weapons','shielding','armour');alien_tech:=tech+3;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at,created_at) VALUES(p_fleet_id,pid,NULL,0,0,0,0,0,0,0,0,f.arrives_at,f.arrives_at) RETURNING id INTO b;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);END LOOP;total:=total+x.quantity;END LOOP;
 roll:=public.expedition_event_random(p_fleet_id,'alien_tier');IF roll<0.89 THEN strength:=0.34+public.expedition_event_random(p_fleet_id,'alien_strength')*0.12;fixed_id:='heavy_fighter';fixed_qty:=5;ELSIF roll<0.99 THEN strength:=0.54+public.expedition_event_random(p_fleet_id,'alien_strength')*0.12;fixed_id:='battlecruiser';fixed_qty:=3;ELSE strength:=0.81+public.expedition_event_random(p_fleet_id,'alien_strength')*0.18;fixed_id:='destroyer';fixed_qty:=2;END IF;
 adapted:=greatest(1,floor(total*strength));SELECT fms.ship_id,sd.attack,sd.shield,sd.hull INTO x FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id ORDER BY fms.quantity DESC,fms.ship_id LIMIT 1;
 FOR n IN 1..adapted LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'DEFENDER','SHIP',x.ship_id,n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x FROM public.ship_definitions sd WHERE sd.id=fixed_id;FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(b,1,'DEFENDER','SHIP',fixed_id,100000+n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);END LOOP;
 UPDATE public.combat_battles cb SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER') WHERE id=b;
 SELECT * INTO v_combat FROM public.run_expedition_combat(b);DELETE FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND NOT EXISTS(SELECT 1 FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.unit_id=fms.ship_id AND ciu.alive);
 UPDATE public.fleet_movement_ships fms SET quantity=q.quantity FROM (SELECT fms2.ship_id,count(*)::bigint quantity FROM public.fleet_movement_ships fms2 JOIN public.combat_individual_units ciu ON ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.unit_id=fms2.ship_id AND ciu.alive WHERE fms2.fleet_id=p_fleet_id GROUP BY fms2.ship_id)q WHERE fms.fleet_id=p_fleet_id AND fms.ship_id=q.ship_id;
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='DEFENDER' GROUP BY ciu.unit_id)q;SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}') INTO surv FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=b AND ciu.side='ATTACKER' AND ciu.alive GROUP BY ciu.unit_id)q;
 INSERT INTO public.expedition_results(fleet_id,player_id,outcome,ships,battle_id,resolved_at,enemy_ships,event_type) VALUES(p_fleet_id,pid,'ALIENS',surv,b,f.arrives_at,enemy,'ALIENS') ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,battle_id=EXCLUDED.battle_id,enemy_ships=EXCLUDED.enemy_ships,event_type='ALIENS',resolved_at=EXCLUDED.resolved_at,ships=EXCLUDED.ships;
 SELECT CASE WHEN cb.attacker_win THEN 'ATTACKER_WIN' WHEN cb.defender_win THEN 'DEFENDER_WIN' ELSE 'DRAW' END INTO res FROM public.combat_battles cb WHERE cb.id=b; battle_id:=b;result:=res;enemy_ships:=enemy;survivors:=surv;RETURN NEXT;
END;$function$;