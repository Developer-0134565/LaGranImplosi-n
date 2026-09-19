CREATE TABLE IF NOT EXISTS public.espionage_reports (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),fleet_id uuid NOT NULL REFERENCES public.fleet_movements(id) ON DELETE CASCADE,player_id uuid NOT NULL,target_planet_id uuid NOT NULL REFERENCES public.planets(id) ON DELETE CASCADE,espionage_level integer NOT NULL DEFAULT 0,target_espionage_level integer NOT NULL DEFAULT 0,metal numeric NOT NULL DEFAULT 0 CHECK(metal>=0),crystal numeric NOT NULL DEFAULT 0 CHECK(crystal>=0),deuterium numeric NOT NULL DEFAULT 0 CHECK(deuterium>=0),energy numeric NOT NULL DEFAULT 0,fleet jsonb NOT NULL DEFAULT '{}'::jsonb,defenses jsonb NOT NULL DEFAULT '{}'::jsonb,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(fleet_id));
INSERT INTO public.ship_definitions(id,name,description,ship_type,base_metal,base_crystal,base_deuterium,base_build_time_seconds,attack,shield,hull,cargo_capacity,fuel_consumption,speed) VALUES('colony_ship','Colony Ship','Ship used to colonize an empty planet position.','support',10000,20000,10000,60,50,100,3000,7500,100,2500) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.ship_prerequisites(ship_id,prerequisite_type,building_id,research_id,required_level) SELECT 'colony_ship','building','shipyard',NULL,4 WHERE NOT EXISTS(SELECT 1 FROM public.ship_prerequisites WHERE ship_id='colony_ship' AND prerequisite_type='building' AND building_id='shipyard');
CREATE OR REPLACE FUNCTION public.resolve_espionage_arrival(p_fleet_id uuid) RETURNS TABLE(fleet_id uuid,target_planet_id uuid,report_id uuid,status text,returns_at timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_fleet record; v_target record; v_report_id uuid; v_duration interval; v_esp integer:=0; v_target_esp integer:=0; v_returns_at timestamptz;
BEGIN
 SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
 IF v_fleet.mission_type<>'ESPIONAGE' THEN RAISE EXCEPTION 'Fleet is not ESPIONAGE'; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Espionage must be ARRIVED'; END IF;
 IF v_fleet.destination_planet_id IS NULL THEN RAISE EXCEPTION 'Espionage has no target'; END IF;
 SELECT p.* INTO v_target FROM public.planets p WHERE p.id=v_fleet.destination_planet_id AND NOT p.is_destroyed FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Target planet not found'; END IF;
 v_esp:=COALESCE(public.get_player_research_level(v_fleet.player_id,'espionage_technology'),0);
 IF v_target.player_id IS NOT NULL THEN v_target_esp:=COALESCE(public.get_player_research_level(v_target.player_id,'espionage_technology'),0); END IF;
 PERFORM public.update_planet_resources_until(v_target.id,now());
 INSERT INTO public.espionage_reports(fleet_id,player_id,target_planet_id,espionage_level,target_espionage_level,metal,crystal,deuterium,energy,fleet,defenses)
 SELECT v_fleet.id,v_fleet.player_id,v_target.id,v_esp,v_target_esp,pr.metal,pr.crystal,pr.deuterium,COALESCE((SELECT SUM(ps.quantity*sd.attack) FROM public.planet_ships ps JOIN public.ship_definitions sd ON sd.id=ps.ship_id WHERE ps.planet_id=v_target.id),0),COALESCE((SELECT jsonb_object_agg(ps.ship_id,ps.quantity) FROM public.planet_ships ps WHERE ps.planet_id=v_target.id),'{}'::jsonb),COALESCE((SELECT jsonb_object_agg(pd.defense_id,pd.quantity) FROM public.planet_defenses pd WHERE pd.planet_id=v_target.id),'{}'::jsonb) FROM public.planet_resources pr WHERE pr.planet_id=v_target.id ON CONFLICT(fleet_id) DO UPDATE SET created_at=now() RETURNING id INTO v_report_id;
 v_duration:=v_fleet.arrives_at-v_fleet.started_at; v_returns_at:=now()+v_duration;
 UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_returns_at WHERE id=p_fleet_id;
 RETURN QUERY SELECT v_fleet.id,v_target.id,v_report_id,'RETURNING'::text,v_returns_at;
END;$function$;
CREATE OR REPLACE FUNCTION public.resolve_colonize_arrival(p_fleet_id uuid) RETURNS TABLE(fleet_id uuid,new_planet_id uuid,galaxy integer,system integer,"position" integer,status text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_fleet record; v_origin record; v_ship_qty bigint:=0; v_new uuid; v_fields integer:=100;
BEGIN
 SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
 IF v_fleet.mission_type<>'COLONIZE' THEN RAISE EXCEPTION 'Fleet is not COLONIZE'; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Colonize must be ARRIVED'; END IF;
 IF v_fleet.destination_planet_id IS NOT NULL THEN RAISE EXCEPTION 'Colonize target must be an empty coordinate'; END IF;
 SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=v_fleet.origin_planet_id FOR UPDATE;
 SELECT COALESCE(SUM(quantity),0) INTO v_ship_qty FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';
 IF v_ship_qty<=0 THEN RAISE EXCEPTION 'Colonize requires colony ship'; END IF;
 IF EXISTS(SELECT 1 FROM public.planets p WHERE p.universe_id=v_origin.universe_id AND p.galaxy=v_fleet.destination_galaxy AND p.system=v_fleet.destination_system AND p.position=v_fleet.destination_position AND NOT p.is_destroyed) THEN
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=now()+(arrives_at-started_at) WHERE id=p_fleet_id;
   RETURN QUERY SELECT v_fleet.id,NULL::uuid,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'RETURNING'::text; RETURN;
 END IF;
 INSERT INTO public.planets(universe_id,player_id,name,galaxy,system,position,temperature_min,temperature_max,fields_total,fields_used,is_homeworld,is_destroyed) VALUES(v_origin.universe_id,v_fleet.player_id,'Colony '||v_fleet.destination_galaxy||':'||v_fleet.destination_system||':'||v_fleet.destination_position,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,-20,20,v_fields,0,false,false) RETURNING id INTO v_new;
 INSERT INTO public.planet_resources(planet_id,metal,crystal,deuterium) VALUES(v_new,0,0,0) ON CONFLICT(planet_id) DO NOTHING;
 DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';
 UPDATE public.fleet_movements SET destination_planet_id=v_new,status='COMPLETED',returns_at=NULL WHERE id=p_fleet_id;
 RETURN QUERY SELECT v_fleet.id,v_new,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'COMPLETED'::text;
END;$function$;
CREATE OR REPLACE FUNCTION public.process_fleet_movements() RETURNS TABLE(fleet_id uuid,previous_status text,new_status text,processed_at timestamptz) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v record; v_duration interval; v_battle uuid; v_last_round integer;
BEGIN
 FOR v IN SELECT fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,fm.destination_galaxy,fm.destination_system,fm.destination_position FROM public.fleet_movements fm WHERE fm.status='OUTBOUND' AND fm.arrives_at<=now() ORDER BY fm.arrives_at FOR UPDATE SKIP LOCKED LOOP
  v_duration:=v.arrives_at-v.started_at; UPDATE public.fleet_movements SET status='ARRIVED' WHERE id=v.id;
  IF v.mission_type='RECYCLE' THEN PERFORM public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position); UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;
  ELSIF v.mission_type='EXPEDITION' THEN PERFORM public.resolve_expedition_arrival(v.id); SELECT er.battle_id INTO v_battle FROM public.expedition_results er WHERE er.fleet_id=v.id AND er.outcome IN('PIRATES','ALIENS'); IF v_battle IS NOT NULL THEN SELECT max(cr.round_number) INTO v_last_round FROM public.combat_rounds cr WHERE cr.battle_id=v_battle; IF v_last_round IS NULL THEN RAISE EXCEPTION 'Expedition battle % finished without rounds',v_battle; END IF; DELETE FROM public.fleet_movement_ships WHERE fleet_id=v.id; INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity) SELECT v.id,ciu.unit_id,count(*)::bigint FROM public.combat_individual_units ciu WHERE ciu.battle_id=v_battle AND ciu.round_number=v_last_round AND ciu.side='ATTACKER' AND ciu.unit_type='SHIP' AND ciu.alive=true GROUP BY ciu.unit_id ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=EXCLUDED.quantity; UPDATE public.expedition_results er SET ships=(SELECT COALESCE(jsonb_object_agg(fms2.ship_id,fms2.quantity),'{}') FROM public.fleet_movement_ships fms2 WHERE fms2.fleet_id=v.id),resolved_at=clock_timestamp() WHERE er.fleet_id=v.id; END IF;
  ELSIF v.mission_type='TRANSPORT' THEN PERFORM public.resolve_transport_arrival(v.id);
  ELSIF v.mission_type='DEPLOY' THEN PERFORM public.resolve_deploy_arrival(v.id);
  ELSIF v.mission_type='ATTACK' THEN PERFORM public.resolve_attack_arrival(v.id);
  ELSIF v.mission_type='ESPIONAGE' THEN PERFORM public.resolve_espionage_arrival(v.id);
  ELSIF v.mission_type='COLONIZE' THEN PERFORM public.resolve_colonize_arrival(v.id);
  ELSE UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id; END IF;
  fleet_id:=v.id;previous_status:='OUTBOUND';new_status:=(SELECT status FROM public.fleet_movements WHERE id=v.id);processed_at=now();RETURN NEXT;
 END LOOP;
 FOR v IN SELECT fm.id,fm.status,fm.mission_type FROM public.fleet_movements fm WHERE fm.status='RETURNING' AND fm.returns_at<=now() ORDER BY fm.returns_at FOR UPDATE SKIP LOCKED LOOP
  IF v.mission_type='EXPEDITION' THEN PERFORM public.resolve_expedition_return(v.id); END IF;
  IF v.mission_type<>'EXPEDITION' OR EXISTS(SELECT 1 FROM public.fleet_movements WHERE id=v.id AND status='RETURNING') THEN INSERT INTO public.planet_ships(planet_id,ship_id,quantity) SELECT fm.origin_planet_id,fms.ship_id,fms.quantity FROM public.fleet_movements fm JOIN public.fleet_movement_ships fms ON fms.fleet_id=fm.id WHERE fm.id=v.id ON CONFLICT(planet_id,ship_id) DO UPDATE SET quantity=public.planet_ships.quantity+EXCLUDED.quantity; UPDATE public.fleet_movements SET status='COMPLETED' WHERE id=v.id AND status='RETURNING'; END IF;
  fleet_id:=v.id;previous_status:='RETURNING';new_status:=(SELECT status FROM public.fleet_movements WHERE id=v.id);processed_at=now();RETURN NEXT;
 END LOOP;
END;$function$;
REVOKE ALL ON FUNCTION public.resolve_espionage_arrival(uuid) FROM PUBLIC; REVOKE ALL ON FUNCTION public.resolve_colonize_arrival(uuid) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.resolve_espionage_arrival(uuid) TO service_role; GRANT EXECUTE ON FUNCTION public.resolve_colonize_arrival(uuid) TO service_role;