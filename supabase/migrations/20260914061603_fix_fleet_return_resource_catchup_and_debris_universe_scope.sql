CREATE OR REPLACE FUNCTION public.collect_debris(p_fleet_id uuid, p_galaxy integer, p_system integer, p_position integer)
RETURNS TABLE(out_fleet_id uuid, out_debris_id uuid, out_capacity numeric, out_metal_collected numeric, out_crystal_collected numeric, out_metal_remaining numeric, out_crystal_remaining numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_debris_id uuid;
    v_debris_metal numeric := 0;
    v_debris_crystal numeric := 0;
    v_capacity numeric := 0;
    v_total_debris numeric := 0;
    v_metal_collected numeric := 0;
    v_crystal_collected numeric := 0;
    v_remaining_capacity numeric := 0;
    v_fleet_universe_id uuid;
BEGIN
    SELECT p.universe_id
    INTO v_fleet_universe_id
    FROM public.fleet_movements fm
    JOIN public.planets p ON p.id = fm.origin_planet_id
    WHERE fm.id = p_fleet_id;

    IF v_fleet_universe_id IS NULL THEN
        RAISE EXCEPTION 'Fleet % or origin universe not found', p_fleet_id;
    END IF;

    SELECT d.id, d.metal, d.crystal
    INTO v_debris_id, v_debris_metal, v_debris_crystal
    FROM public.debris_fields d
    WHERE d.universe_id = v_fleet_universe_id
      AND d.galaxy = p_galaxy
      AND d.system = p_system
      AND d."position" = p_position
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No debris field at [%:%:%] in universe %', p_galaxy, p_system, p_position, v_fleet_universe_id;
    END IF;

    v_capacity := public.calculate_recycler_capacity(p_fleet_id);
    IF v_capacity <= 0 THEN
        RAISE EXCEPTION 'Fleet % contains no Recycler', p_fleet_id;
    END IF;

    v_total_debris := v_debris_metal + v_debris_crystal;
    IF v_total_debris <= 0 THEN
        RAISE EXCEPTION 'Debris field is empty';
    END IF;

    v_remaining_capacity := LEAST(v_capacity, v_total_debris);
    v_metal_collected := LEAST(v_remaining_capacity * (v_debris_metal / v_total_debris), v_debris_metal);
    v_crystal_collected := LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal);

    UPDATE public.debris_fields d
    SET metal = GREATEST(0, d.metal - v_metal_collected),
        crystal = GREATEST(0, d.crystal - v_crystal_collected),
        updated_at = now()
    WHERE d.id = v_debris_id;

    DELETE FROM public.debris_fields d
    WHERE d.id = v_debris_id AND d.metal <= 0 AND d.crystal <= 0;

    RETURN QUERY
    SELECT p_fleet_id,
           v_debris_id,
           v_capacity,
           v_metal_collected,
           v_crystal_collected,
           COALESCE((SELECT d.metal FROM public.debris_fields d WHERE d.id = v_debris_id), 0),
           COALESCE((SELECT d.crystal FROM public.debris_fields d WHERE d.id = v_debris_id), 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_fleet_movements()
RETURNS TABLE(fleet_id uuid, previous_status text, new_status text, processed_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
    SELECT fm.id,fm.status,fm.mission_type
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

      -- The returning fleet's cargo must be delivered on top of resources
      -- already produced up to the exact return instant. Otherwise setting
      -- updated_at=now() below would erase offline production accumulated
      -- during the return flight.
      IF v.mission_type<>'EXPEDITION' THEN
        PERFORM public.update_planet_resources_until(
          (SELECT fm.origin_planet_id FROM public.fleet_movements fm WHERE fm.id=v.id),
          now()
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
          updated_at=now()
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
$function$;