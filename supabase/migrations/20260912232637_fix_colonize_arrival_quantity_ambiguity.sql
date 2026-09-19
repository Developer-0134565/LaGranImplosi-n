CREATE OR REPLACE FUNCTION public.resolve_colonize_arrival(p_fleet_id uuid) RETURNS TABLE(fleet_id uuid,new_planet_id uuid,galaxy integer,system integer,"position" integer,status text) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_fleet record; v_origin record; v_ship_qty bigint:=0; v_new uuid; v_fields integer:=100;
BEGIN
 SELECT fm.* INTO v_fleet FROM public.fleet_movements fm WHERE fm.id=p_fleet_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found'; END IF;
 IF v_fleet.mission_type<>'COLONIZE' THEN RAISE EXCEPTION 'Fleet is not COLONIZE'; END IF;
 IF v_fleet.status<>'ARRIVED' THEN RAISE EXCEPTION 'Colonize must be ARRIVED'; END IF;
 IF v_fleet.destination_planet_id IS NOT NULL THEN RAISE EXCEPTION 'Colonize target must be an empty coordinate'; END IF;
 SELECT p.* INTO v_origin FROM public.planets p WHERE p.id=v_fleet.origin_planet_id FOR UPDATE;
 SELECT COALESCE(SUM(fms.quantity),0) INTO v_ship_qty FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND fms.ship_id='colony_ship';
 IF v_ship_qty<=0 THEN RAISE EXCEPTION 'Colonize requires colony ship'; END IF;
 IF EXISTS(SELECT 1 FROM public.planets p WHERE p.universe_id=v_origin.universe_id AND p.galaxy=v_fleet.destination_galaxy AND p.system=v_fleet.destination_system AND p.position=v_fleet.destination_position AND NOT p.is_destroyed) THEN
   UPDATE public.fleet_movements fm SET status='RETURNING',returns_at=now()+(fm.arrives_at-fm.started_at) WHERE fm.id=p_fleet_id;
   RETURN QUERY SELECT v_fleet.id,NULL::uuid,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'RETURNING'::text; RETURN;
 END IF;
 INSERT INTO public.planets(universe_id,player_id,name,galaxy,system,position,temperature_min,temperature_max,fields_total,fields_used,is_homeworld,is_destroyed) VALUES(v_origin.universe_id,v_fleet.player_id,'Colony '||v_fleet.destination_galaxy||':'||v_fleet.destination_system||':'||v_fleet.destination_position,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,-20,20,v_fields,0,false,false) RETURNING id INTO v_new;
 INSERT INTO public.planet_resources(planet_id,metal,crystal,deuterium) VALUES(v_new,0,0,0) ON CONFLICT(planet_id) DO NOTHING;
 DELETE FROM public.fleet_movement_ships fms WHERE fms.fleet_id=p_fleet_id AND fms.ship_id='colony_ship';
 UPDATE public.fleet_movements fm SET destination_planet_id=v_new,status='COMPLETED',returns_at=NULL WHERE fm.id=p_fleet_id;
 RETURN QUERY SELECT v_fleet.id,v_new,v_fleet.destination_galaxy,v_fleet.destination_system,v_fleet.destination_position,'COMPLETED'::text;
END;$function$;