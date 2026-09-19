CREATE OR REPLACE FUNCTION public.resolve_expedition_pirates(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid,battle_result text,enemy_ships jsonb,surviving_ships jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE f RECORD; v_battle uuid; pid uuid; tier integer; strength numeric; fixed_id text; fixed_qty integer; w integer; sh integer; a integer; pw integer; psh integer; pa integer; att bigint:=0; def bigint:=0; enemy jsonb; surv jsonb; x RECORD; n integer; atk numeric; shield numeric; hull numeric; run RECORD;
BEGIN
 SELECT fm.* INTO f FROM public.fleet_movements fm WHERE fm.id=p_fleet_id AND fm.mission_type='EXPEDITION' FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
 pid:=f.player_id;
 IF EXISTS(SELECT 1 FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='deathstar' AND quantity>0) THEN RAISE EXCEPTION 'Deathstar expeditions cannot receive pirate combat'; END IF;
 SELECT COALESCE(pr.level,0) INTO w FROM public.research_definitions rd LEFT JOIN public.player_research pr ON pr.research_id=rd.id AND pr.player_id=pid WHERE rd.id='weapons_technology';
 SELECT COALESCE(pr.level,0) INTO sh FROM public.research_definitions rd LEFT JOIN public.player_research pr ON pr.research_id=rd.id AND pr.player_id=pid WHERE rd.id='shielding_technology';
 SELECT COALESCE(pr.level,0) INTO a FROM public.research_definitions rd LEFT JOIN public.player_research pr ON pr.research_id=rd.id AND pr.player_id=pid WHERE rd.id='armour_technology';
 pw:=greatest(w-3,3); psh:=greatest(sh-3,3); pa:=greatest(a-3,3); tier:=floor(random()*100)+1;
 IF tier<=89 THEN strength:=0.27+random()*0.06; fixed_id:='light_fighter'; fixed_qty:=5; ELSIF tier<=99 THEN strength:=0.45+random()*0.10; fixed_id:='cruiser'; fixed_qty:=3; ELSE strength:=0.72+random()*0.16; fixed_id:='battleship'; fixed_qty:=2; END IF;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at) VALUES(p_fleet_id,pid,f.origin_planet_id,0,0,0,0,0,0,0,0,clock_timestamp()) RETURNING id INTO v_battle;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP
   atk:=x.attack*(1+w*0.10); shield:=x.shield*(1+sh*0.10); hull:=x.hull*(1+a*0.10);
   FOR n IN 1..x.quantity LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'ATTACKER','SHIP',x.ship_id,n,atk,shield,shield,hull,hull,hull,true); att:=att+1; END LOOP;
 END LOOP;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 AND fms.ship_id NOT IN('recycler','colony_ship','deathstar','espionage_probe') LOOP
   IF floor(x.quantity*strength)>0 THEN atk:=x.attack*(1+pw*0.10); shield:=x.shield*(1+psh*0.10); hull:=x.hull*(1+pa*0.10); FOR n IN 1..floor(x.quantity*strength) LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',x.ship_id,n,atk,shield,shield,hull,hull,hull,true); def:=def+1; END LOOP; END IF;
 END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO atk,shield,hull FROM public.ship_definitions sd WHERE sd.id=fixed_id; atk:=atk*(1+pw*0.10); shield:=shield*(1+psh*0.10); hull:=hull*(1+pa*0.10);
 FOR n IN 1..fixed_qty LOOP INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive) VALUES(v_battle,1,'DEFENDER','SHIP',fixed_id,100000+n,atk,shield,shield,hull,hull,hull,true); def:=def+1; END LOOP;
 UPDATE public.combat_battles SET attacker_ships_before=att,attacker_ships_after=att,defender_ships_before=def,defender_ships_after=def,defender_defenses_before=0,defender_defenses_after=0,defender_combat_units_before=def,defender_combat_units_after=def WHERE id=v_battle;
 SELECT COALESCE(jsonb_object_agg(q.unit_id,q.quantity),'{}'::jsonb) INTO enemy FROM(SELECT ciu.unit_id,count(*)::bigint quantity FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.side='DEFENDER' GROUP BY ciu.unit_id) q;
 SELECT * INTO run FROM public.run_expedition_combat(v_battle);
 PERFORM public.finish_combat_battle(v_battle);
 DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id;
 INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) SELECT p_fleet_id,ciu.unit_id,count(*)::bigint FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.round_number=run.rounds_played AND ciu.side='ATTACKER' AND ciu.alive=true GROUP BY ciu.unit_id;
 SELECT COALESCE(jsonb_object_agg(fms.ship_id,fms.quantity),'{}'::jsonb) INTO surv FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id;
 RETURN QUERY SELECT v_battle,run.battle_result,enemy,surv;
END;
$function$;