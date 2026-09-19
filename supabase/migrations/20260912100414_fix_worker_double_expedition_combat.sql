CREATE OR REPLACE FUNCTION public.process_fleet_movements()
RETURNS TABLE(fleet_id uuid,previous_status text,new_status text,processed_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE v RECORD; v_duration interval; v_battle uuid; v_last_round integer;
BEGIN
 FOR v IN SELECT fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,fm.destination_galaxy,fm.destination_system,fm.destination_position FROM public.fleet_movements fm WHERE fm.status='OUTBOUND' AND fm.arrives_at<=now() ORDER BY fm.arrives_at FOR UPDATE SKIP LOCKED LOOP
  v_duration:=v.arrives_at-v.started_at;
  UPDATE public.fleet_movements SET status='ARRIVED' WHERE id=v.id;
  IF v.mission_type='RECYCLE' THEN
   PERFORM public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;
   fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='RETURNING';processed_at:=now();RETURN NEXT;
  ELSIF v.mission_type='EXPEDITION' THEN
   -- resolve_expedition_arrival es el único dueño del resultado y del combate.
   PERFORM public.resolve_expedition_arrival(v.id);
   SELECT er.battle_id INTO v_battle FROM public.expedition_results er WHERE er.fleet_id=v.id AND er.outcome='PIRATES';
   IF v_battle IS NOT NULL THEN
    SELECT max(cr.round_number) INTO v_last_round FROM public.combat_rounds cr WHERE cr.battle_id=v_battle;
    IF v_last_round IS NULL THEN RAISE EXCEPTION 'Pirate battle % finished without rounds',v_battle; END IF;
    -- Aplicamos las bajas del combate a la flota que volverá.
    DELETE FROM public.fleet_movement_ships WHERE fleet_id=v.id;
    INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
    SELECT v.id,ciu.unit_id,count(*)::bigint
    FROM public.combat_individual_units ciu
    WHERE ciu.battle_id=v_battle AND ciu.round_number=v_last_round AND ciu.side='ATTACKER' AND ciu.alive=true
    GROUP BY ciu.unit_id;
    UPDATE public.expedition_results er SET battle_id=v_battle,ships=(SELECT COALESCE(jsonb_object_agg(fms.ship_id,fms.quantity),'{}'::jsonb) FROM public.fleet_movement_ships fms WHERE fms.fleet_id=v.id),resolved_at=clock_timestamp() WHERE er.fleet_id=v.id;
   END IF;
   fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='RETURNING';processed_at:=now();RETURN NEXT;
  ELSIF v.mission_type='TRANSPORT' THEN
   PERFORM public.resolve_transport_arrival(v.id);fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='RETURNING';processed_at:=now();RETURN NEXT;
  ELSIF v.mission_type='DEPLOY' THEN
   PERFORM public.resolve_deploy_arrival(v.id);fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='COMPLETED';processed_at:=now();RETURN NEXT;
  ELSIF v.mission_type='ATTACK' THEN
   PERFORM public.resolve_attack_arrival(v.id);fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='ARRIVED';processed_at:=now();RETURN NEXT;
  ELSE
   UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;fleet_id:=v.id;previous_status:='OUTBOUND';new_status:='RETURNING';processed_at:=now();RETURN NEXT;
  END IF;
 END LOOP;
 FOR v IN SELECT fm.id,fm.status,fm.mission_type FROM public.fleet_movements fm WHERE fm.status='RETURNING' AND fm.returns_at<=now() ORDER BY fm.returns_at FOR UPDATE SKIP LOCKED LOOP
  IF v.mission_type='EXPEDITION' THEN
   PERFORM public.resolve_expedition_return(v.id);
   INSERT INTO public.planet_ships(planet_id,ship_id,quantity) SELECT fm.origin_planet_id,fms.ship_id,fms.quantity FROM public.fleet_movements fm JOIN public.fleet_movement_ships fms ON fms.fleet_id=fm.id WHERE fm.id=v.id ON CONFLICT(planet_id,ship_id) DO UPDATE SET quantity=public.planet_ships.quantity+EXCLUDED.quantity;
   fleet_id:=v.id;previous_status:='RETURNING';new_status:='COMPLETED';processed_at:=now();RETURN NEXT;
  ELSE
   INSERT INTO public.planet_ships(planet_id,ship_id,quantity) SELECT fm.origin_planet_id,fms.ship_id,fms.quantity FROM public.fleet_movements fm JOIN public.fleet_movement_ships fms ON fms.fleet_id=fm.id WHERE fm.id=v.id ON CONFLICT(planet_id,ship_id) DO UPDATE SET quantity=public.planet_ships.quantity+EXCLUDED.quantity;
   UPDATE public.fleet_movements SET status='COMPLETED' WHERE id=v.id;
   fleet_id:=v.id;previous_status:='RETURNING';new_status:='COMPLETED';processed_at:=now();RETURN NEXT;
  END IF;
 END LOOP;
END;
$function$;