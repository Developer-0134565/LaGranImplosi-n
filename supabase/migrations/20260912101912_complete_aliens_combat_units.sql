CREATE OR REPLACE FUNCTION public.resolve_expedition_aliens(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid, result text, enemy_ships jsonb, survivors jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE
 f public.fleet_movements%ROWTYPE; b uuid; pid uuid; total bigint:=0; adapted bigint; fixed_id text; fixed_qty int; roll numeric; strength numeric; tech int; alien_tech int; enemy jsonb:='{}'; surv jsonb:='{}'; res text; x record; n int;
BEGIN
 SELECT * INTO f FROM public.fleet_movements WHERE id=p_fleet_id AND mission_type='EXPEDITION' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found',p_fleet_id; END IF;
 SELECT er.battle_id,er.outcome,COALESCE(er.enemy_ships,'{}'),COALESCE(er.ships,'{}') INTO battle_id,result,enemy_ships,survivors FROM public.expedition_results er WHERE er.fleet_id=p_fleet_id AND er.outcome='ALIENS';
 IF FOUND THEN RETURN NEXT; RETURN; END IF;
 IF f.status<>'ARRIVED' THEN RAISE EXCEPTION 'Expedition fleet % must be ARRIVED',p_fleet_id; END IF;
 pid:=f.player_id;
 SELECT COALESCE(MAX(pr.level),0) INTO tech FROM public.player_research pr JOIN public.research_definitions rd ON rd.id=pr.research_id WHERE pr.player_id=pid AND rd.id IN('weapons','shielding','armour');
 alien_tech:=tech+3;
 INSERT INTO public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,defender_combat_units_before,defender_combat_units_after,started_at,created_at)
 VALUES(p_fleet_id,pid,NULL,0,0,0,0,0,0,0,0,clock_timestamp(),clock_timestamp()) RETURNING id INTO b;
 FOR x IN SELECT fms.ship_id,fms.quantity,sd.attack,sd.shield,sd.hull FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id AND fms.quantity>0 LOOP
   FOR n IN 1..x.quantity LOOP
     INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)
     VALUES(b,1,'ATTACKER','SHIP',x.ship_id,n,x.attack,x.shield,x.shield,x.hull,x.hull,x.hull,true);
   END LOOP; total:=total+x.quantity;
 END LOOP;
 roll:=random()*100;
 IF roll<89 THEN strength:=0.34+random()*0.12;fixed_id:='heavy_fighter';fixed_qty:=5;
 ELSIF roll<99 THEN strength:=0.54+random()*0.12;fixed_id:='battlecruiser';fixed_qty:=3;
 ELSE strength:=0.81+random()*0.18;fixed_id:='destroyer';fixed_qty:=2; END IF;
 adapted:=greatest(1,floor(total*strength));
 SELECT fms.ship_id,sd.attack,sd.shield,sd.hull INTO x FROM public.fleet_movement_ships fms JOIN public.ship_definitions sd ON sd.id=fms.ship_id WHERE fms.fleet_id=p_fleet_id ORDER BY fms.quantity DESC,fms.ship_id LIMIT 1;
 FOR n IN 1..adapted LOOP
   INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)
   VALUES(b,1,'DEFENDER','SHIP',x.ship_id,n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);
 END LOOP;
 SELECT sd.attack,sd.shield,sd.hull INTO x FROM public.ship_definitions sd WHERE sd.id=fixed_id;
 FOR n IN 1..fixed_qty LOOP
   INSERT INTO public.combat_individual_units(battle_id,round_number,side,unit_type,unit_id,unit_number,attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)
   VALUES(b,1,'DEFENDER','SHIP',fixed_id,100000+n,round(x.attack*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.shield*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),round(x.hull*(1+alien_tech*0.10)),true);
 END LOOP;
 UPDATE public.combat_battles SET attacker_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),attacker_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER'),defender_ships_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_ships_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_before=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER'),defender_combat_units_after=(SELECT count(*) FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER') WHERE id=b;
 SELECT COALESCE(jsonb_object_agg(unit_id,qty),'{}') INTO enemy FROM(SELECT unit_id,count(*) qty FROM public.combat_individual_units WHERE battle_id=b AND side='DEFENDER' GROUP BY unit_id)q;
 INSERT INTO public.expedition_results(fleet_id,player_id,outcome,ships,battle_id,resolved_at,enemy_ships,event_type) VALUES(p_fleet_id,pid,'ALIENS','{}',b,now(),enemy,'ALIENS') ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,battle_id=EXCLUDED.battle_id,enemy_ships=EXCLUDED.enemy_ships,event_type='ALIENS',resolved_at=EXCLUDED.resolved_at;
 SELECT * INTO x FROM public.run_expedition_combat(b);
 SELECT COALESCE(jsonb_object_agg(unit_id,qty),'{}') INTO surv FROM(SELECT unit_id,count(*) qty FROM public.combat_individual_units WHERE battle_id=b AND side='ATTACKER' AND alive GROUP BY unit_id)q;
 UPDATE public.expedition_results SET ships=surv WHERE fleet_id=p_fleet_id;
 SELECT CASE WHEN cb.attacker_win THEN 'ATTACKER_WIN' WHEN cb.defender_win THEN 'DEFENDER_WIN' ELSE 'DRAW' END INTO res FROM public.combat_battles cb WHERE cb.id=b;
 battle_id:=b;result:=res;enemy_ships:=enemy;survivors:=surv;RETURN NEXT;
END;$function$;