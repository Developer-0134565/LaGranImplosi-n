DO $$
BEGIN
  EXECUTE replace(
    pg_get_functiondef('public.start_building(uuid,uuid,text)'::regprocedure),
    'PERFORM public.update_planet_resources(p_planet_id);',
    'PERFORM public.process_planet_tick(p_planet_id);'
  );
  EXECUTE replace(
    pg_get_functiondef('public.start_research(uuid,uuid,text)'::regprocedure),
    'PERFORM public.update_planet_resources(p_planet_id);',
    'PERFORM public.process_planet_tick(p_planet_id);'
  );
  EXECUTE replace(
    pg_get_functiondef('public.start_ship(uuid,uuid,text,bigint)'::regprocedure),
    'PERFORM public.update_planet_resources(p_planet_id);',
    'PERFORM public.process_planet_tick(p_planet_id);'
  );
  EXECUTE replace(
    pg_get_functiondef('public.start_defense(uuid,uuid,text,bigint)'::regprocedure),
    'PERFORM public.update_planet_resources(p_planet_id);',
    'PERFORM public.process_planet_tick(p_planet_id);'
  );
END $$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_return(p_fleet_id uuid)
RETURNS TABLE(fleet_id uuid, origin_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_fleet RECORD;
    v_return_at timestamptz;
BEGIN
    SELECT fm.id, fm.origin_planet_id, fm.mission_type, fm.status,
           fm.metal, fm.crystal, fm.deuterium, fm.returns_at
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet not found: %', p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet is not an EXPEDITION'; END IF;
    IF v_fleet.status <> 'RETURNING' THEN RAISE EXCEPTION 'Expedition must be RETURNING. Current status: %', v_fleet.status; END IF;

    v_return_at := COALESCE(v_fleet.returns_at, now());

    -- A late worker must settle the planet only through the scheduled return
    -- event. Later economic queue events are then processed chronologically by
    -- process_planet_tick/process_universe_tick instead of being skipped.
    PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id, v_return_at);

    INSERT INTO public.planet_ships(planet_id, ship_id, quantity)
    SELECT v_fleet.origin_planet_id, fms.ship_id, fms.quantity
    FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id = p_fleet_id
    ON CONFLICT(planet_id, ship_id)
    DO UPDATE SET quantity = public.planet_ships.quantity + EXCLUDED.quantity;

    UPDATE public.planet_resources pr
    SET metal = pr.metal + v_fleet.metal,
        crystal = pr.crystal + v_fleet.crystal,
        deuterium = pr.deuterium + v_fleet.deuterium,
        updated_at = clock_timestamp()
    WHERE pr.planet_id = v_fleet.origin_planet_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet resources not found'; END IF;

    UPDATE public.fleet_movements
    SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
    WHERE id = p_fleet_id AND status = 'RETURNING';

    fleet_id := v_fleet.id;
    origin_planet_id := v_fleet.origin_planet_id;
    delivered_metal := v_fleet.metal;
    delivered_crystal := v_fleet.crystal;
    delivered_deuterium := v_fleet.deuterium;
    status := 'COMPLETED';
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_fleet_movements()
RETURNS TABLE(fleet_id uuid, previous_status text, new_status text, processed_at timestamp with time zone)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v record;
  v_duration interval;
  v_battle uuid;
  v_last_round integer;
  v_recycle record;
BEGIN
  FOR v IN
    SELECT fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,
           fm.destination_galaxy,fm.destination_system,fm.destination_position
    FROM public.fleet_movements fm
    WHERE fm.status='OUTBOUND' AND fm.arrives_at<=now()
    ORDER BY fm.arrives_at
    FOR UPDATE SKIP LOCKED
  LOOP
    v_duration := v.arrives_at-v.started_at;
    UPDATE public.fleet_movements SET status='ARRIVED' WHERE id=v.id;

    IF v.mission_type='RECYCLE' THEN
      SELECT * INTO v_recycle
      FROM public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);

      UPDATE public.fleet_movements
      SET metal=COALESCE(v_recycle.out_metal_collected,0),
          crystal=COALESCE(v_recycle.out_crystal_collected,0),
          deuterium=0,
          status='RETURNING',
          returns_at=v.arrives_at+v_duration
      WHERE id=v.id;

    ELSIF v.mission_type='EXPEDITION' THEN
      PERFORM public.resolve_expedition_arrival(v.id);
      SELECT er.battle_id INTO v_battle
      FROM public.expedition_results er
      WHERE er.fleet_id=v.id AND er.outcome IN('PIRATES','ALIENS');
      IF v_battle IS NOT NULL THEN
        SELECT max(cr.round_number) INTO v_last_round
        FROM public.combat_rounds cr WHERE cr.battle_id=v_battle;
        IF v_last_round IS NULL THEN RAISE EXCEPTION 'Expedition battle % finished without rounds',v_battle; END IF;
        DELETE FROM public.fleet_movement_ships WHERE fleet_id=v.id;
        INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
        SELECT v.id,ciu.unit_id,count(*)::bigint
        FROM public.combat_individual_units ciu
        WHERE ciu.battle_id=v_battle AND ciu.round_number=v_last_round
          AND ciu.side='ATTACKER' AND ciu.unit_type='SHIP' AND ciu.alive=true
        GROUP BY ciu.unit_id
        ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=EXCLUDED.quantity;
        UPDATE public.expedition_results er
        SET ships=(SELECT COALESCE(jsonb_object_agg(fms2.ship_id,fms2.quantity),'{}')
                   FROM public.fleet_movement_ships fms2 WHERE fms2.fleet_id=v.id),
            resolved_at=clock_timestamp()
        WHERE er.fleet_id=v.id;
      END IF;
    ELSIF v.mission_type='TRANSPORT' THEN
      PERFORM public.resolve_transport_arrival(v.id);
    ELSIF v.mission_type='DEPLOY' THEN
      PERFORM public.resolve_deploy_arrival(v.id);
    ELSIF v.mission_type='ATTACK' THEN
      PERFORM public.resolve_attack_arrival(v.id);
    ELSIF v.mission_type='ESPIONAGE' THEN
      PERFORM public.resolve_espionage_arrival(v.id);
    ELSIF v.mission_type='COLONIZE' THEN
      PERFORM public.resolve_colonize_arrival(v.id);
    ELSE
      UPDATE public.fleet_movements SET status='RETURNING',returns_at=v.arrives_at+v_duration WHERE id=v.id;
    END IF;

    fleet_id:=v.id; previous_status:='OUTBOUND';
    new_status:=(SELECT status FROM public.fleet_movements WHERE id=v.id);
    processed_at=now(); RETURN NEXT;
  END LOOP;

  FOR v IN
    SELECT fm.id,fm.status,fm.mission_type,fm.returns_at
    FROM public.fleet_movements fm
    WHERE fm.status='RETURNING' AND fm.returns_at<=now()
    ORDER BY fm.returns_at
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v.mission_type='EXPEDITION' THEN
      PERFORM public.resolve_expedition_return(v.id);
    END IF;

    IF v.mission_type<>'EXPEDITION'
       OR EXISTS(SELECT 1 FROM public.fleet_movements WHERE id=v.id AND status='RETURNING') THEN

      -- Settle exactly through the scheduled return event. This keeps offline
      -- production correct and leaves any later building/research completion
      -- for the chronological economy tick.
      IF v.mission_type<>'EXPEDITION' THEN
        PERFORM public.update_planet_resources_until(
          (SELECT fm.origin_planet_id FROM public.fleet_movements fm WHERE fm.id=v.id),
          v.returns_at
        );
      END IF;

      INSERT INTO public.planet_ships(planet_id,ship_id,quantity)
      SELECT fm.origin_planet_id,fms.ship_id,fms.quantity
      FROM public.fleet_movements fm
      JOIN public.fleet_movement_ships fms ON fms.fleet_id=fm.id
      WHERE fm.id=v.id
      ON CONFLICT(planet_id,ship_id)
      DO UPDATE SET quantity=public.planet_ships.quantity+EXCLUDED.quantity;

      UPDATE public.planet_resources pr
      SET metal=pr.metal+fm.metal,
          crystal=pr.crystal+fm.crystal,
          deuterium=pr.deuterium+fm.deuterium,
          updated_at=clock_timestamp()
      FROM public.fleet_movements fm
      WHERE fm.id=v.id
        AND pr.planet_id=fm.origin_planet_id
        AND (fm.metal<>0 OR fm.crystal<>0 OR fm.deuterium<>0);

      UPDATE public.fleet_movements
      SET metal=0,crystal=0,deuterium=0,status='COMPLETED'
      WHERE id=v.id AND status='RETURNING';
    END IF;

    fleet_id:=v.id; previous_status:='RETURNING';
    new_status:=(SELECT status FROM public.fleet_movements WHERE id=v.id);
    processed_at=now(); RETURN NEXT;
  END LOOP;
END;
$$;