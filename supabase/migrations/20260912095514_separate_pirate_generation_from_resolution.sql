CREATE OR REPLACE FUNCTION public.resolve_expedition_pirates(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid,battle_result text,enemy_ships jsonb,surviving_ships jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE f RECORD; v_battle uuid; pid uuid; tier integer; strength numeric; fixed_id text; fixed_qty integer; x RECORD; n integer; enemy jsonb; original jsonb;
BEGIN
 SELECT fm.* INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
 pid:=f.player_id;
 IF EXISTS(SELECT 1 FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='deathstar' AND quantity>0) THEN RAISE EXCEPTION 'Deathstar expeditions cannot receive pirate combat'; END IF;
 tier:=floor(random()*100)+1;
 IF tier<=89 THEN strength:=0.27+random()*0.06; fixed_id:='light_fighter'; fixed_qty:=5; ELSIF tier<=99 THEN strength:=0.45+random()*0.10; fixed_id:='cruiser'; fixed_qty:=3; ELSE strength:=0.72+random()*0.16; fixed_id:='battleship'; fixed_qty:=2; END IF;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at) VALUES(p_fleet_id,pid,f.origin_planet_id,0,0,0,0,0,0,0,0,clock_timestamp()) RETURNING id INTO v_battle;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP
   FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP;
 END LOOP;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 AND fms.ship_id NOT IN('recycler','colony_ship','deathstar','espionage_probe') LOOP
   FOR n IN 1..floor(x.quantity*strength) LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP;
 END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x.attack,x.shield,x.hull FROM public.ship_definitions sd WHERE sd.id=fixed_id;
 FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',fixed_id,100000+n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true); END LOOP;
 UPDATE public.combat_battles SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=v_battle AND side='DEFENDER') WHERE id=v_battle;
 PERFORM public.create_combat_round_snapshot(v_battle,1);
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}'::jsonb) INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='DEFENDER' GROUP BY ciu.unit_id) q;
 SELECT COALESCE(jsonb_object_agg(fms.ship_id,fms.quantity),'{}'::jsonb) INTO original FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id;
 RETURN QUERY SELECT v_battle,'PENDING',enemy,original;
END;
$function$;