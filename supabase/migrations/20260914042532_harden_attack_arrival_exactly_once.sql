CREATE OR REPLACE FUNCTION public.resolve_attack_arrival(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fleet public.fleet_movements%ROWTYPE;
    v_battle_id uuid;
    v_last_round integer;
    v_duration interval;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fleet % no existe', p_fleet_id;
    END IF;

    IF v_fleet.mission_type <> 'ATTACK' THEN
        RAISE EXCEPTION 'Fleet % no es ATTACK', p_fleet_id;
    END IF;

    IF v_fleet.status NOT IN ('ARRIVED','RETURNING','COMPLETED') THEN
        RAISE EXCEPTION 'Fleet % no está lista para resolver ataque. Estado: %', p_fleet_id, v_fleet.status;
    END IF;

    SELECT cb.id INTO v_battle_id
    FROM public.combat_battles cb
    WHERE cb.fleet_id = p_fleet_id
    ORDER BY cb.created_at
    LIMIT 1
    FOR UPDATE;

    IF v_battle_id IS NULL THEN
        v_battle_id := public.resolve_combat(p_fleet_id);
    END IF;

    -- Once the fleet has left ARRIVED, all combat side effects have already
    -- been committed in the same transaction that changed the fleet state.
    -- A retry must therefore be a pure no-op instead of reapplying repairs,
    -- planet losses, debris, or fleet cargo.
    IF v_fleet.status <> 'ARRIVED' THEN
        RETURN v_battle_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.combat_battles
        WHERE id = v_battle_id AND finished_at IS NOT NULL
    ) THEN
        PERFORM public.run_expedition_combat(v_battle_id);
    END IF;

    SELECT max(round_number)
    INTO v_last_round
    FROM public.combat_individual_units
    WHERE battle_id = v_battle_id;

    IF v_last_round IS NULL THEN
        RAISE EXCEPTION 'Battle % finished without rounds', v_battle_id;
    END IF;

    PERFORM public.sync_combat_battle_final_counts(v_battle_id);

    DELETE FROM public.fleet_movement_ships
    WHERE fleet_id = p_fleet_id;

    INSERT INTO public.fleet_movement_ships(fleet_id, ship_id, quantity)
    SELECT p_fleet_id, ciu.unit_id, count(*)::bigint
    FROM public.combat_individual_units ciu
    WHERE ciu.battle_id = v_battle_id
      AND ciu.round_number = v_last_round
      AND ciu.side = 'ATTACKER'
      AND ciu.unit_type = 'SHIP'
      AND ciu.alive
    GROUP BY ciu.unit_id;

    UPDATE public.planet_ships ps
    SET quantity = COALESCE(src.quantity, 0)
    FROM (
        SELECT ciu.unit_id, count(*)::bigint quantity
        FROM public.combat_individual_units ciu
        WHERE ciu.battle_id = v_battle_id
          AND ciu.round_number = v_last_round
          AND ciu.side = 'DEFENDER'
          AND ciu.unit_type = 'SHIP'
          AND ciu.alive
        GROUP BY ciu.unit_id
    ) src
    WHERE ps.planet_id = v_fleet.destination_planet_id
      AND ps.ship_id = src.unit_id;

    UPDATE public.planet_ships ps
    SET quantity = 0
    WHERE ps.planet_id = v_fleet.destination_planet_id
      AND EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id = v_battle_id
            AND ciu.round_number = v_last_round
            AND ciu.side = 'DEFENDER'
            AND ciu.unit_type = 'SHIP'
            AND ciu.unit_id = ps.ship_id
      )
      AND NOT EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id = v_battle_id
            AND ciu.round_number = v_last_round
            AND ciu.side = 'DEFENDER'
            AND ciu.unit_type = 'SHIP'
            AND ciu.unit_id = ps.ship_id
            AND ciu.alive
      );

    UPDATE public.planet_defenses pd
    SET quantity = COALESCE(src.quantity, 0)
    FROM (
        SELECT ciu.unit_id, count(*)::bigint quantity
        FROM public.combat_individual_units ciu
        WHERE ciu.battle_id = v_battle_id
          AND ciu.round_number = v_last_round
          AND ciu.side = 'DEFENDER'
          AND ciu.unit_type = 'DEFENSE'
          AND ciu.alive
        GROUP BY ciu.unit_id
    ) src
    WHERE pd.planet_id = v_fleet.destination_planet_id
      AND pd.defense_id = src.unit_id;

    UPDATE public.planet_defenses pd
    SET quantity = 0
    WHERE pd.planet_id = v_fleet.destination_planet_id
      AND EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id = v_battle_id
            AND ciu.round_number = v_last_round
            AND ciu.side = 'DEFENDER'
            AND ciu.unit_type = 'DEFENSE'
            AND ciu.unit_id = pd.defense_id
      )
      AND NOT EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id = v_battle_id
            AND ciu.round_number = v_last_round
            AND ciu.side = 'DEFENDER'
            AND ciu.unit_type = 'DEFENSE'
            AND ciu.unit_id = pd.defense_id
            AND ciu.alive
      );

    PERFORM * FROM public.repair_defenses_after_combat(v_battle_id);
    PERFORM public.create_combat_debris(v_battle_id);

    v_duration := v_fleet.arrives_at - v_fleet.started_at;

    UPDATE public.fleet_movements
    SET status = 'RETURNING',
        returns_at = arrives_at + v_duration
    WHERE id = p_fleet_id
      AND status = 'ARRIVED';

    RETURN v_battle_id;
END;
$function$;