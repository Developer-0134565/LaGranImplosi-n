CREATE TABLE IF NOT EXISTS public.combat_defense_repairs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    battle_id uuid NOT NULL REFERENCES public.combat_battles(id) ON DELETE CASCADE,
    planet_id uuid NOT NULL REFERENCES public.planets(id) ON DELETE CASCADE,
    defense_id text NOT NULL REFERENCES public.defense_definitions(id),
    destroyed_quantity bigint NOT NULL CHECK (destroyed_quantity >= 0),
    repaired_quantity bigint NOT NULL CHECK (repaired_quantity >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (battle_id, defense_id)
);

CREATE OR REPLACE FUNCTION public.repair_defenses_after_combat(p_battle_id uuid)
RETURNS TABLE(defense_id text, destroyed_quantity bigint, repaired_quantity bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_battle public.combat_battles%ROWTYPE;
    v_loss record;
    v_repaired bigint;
BEGIN
    SELECT * INTO v_battle
    FROM public.combat_battles
    WHERE id = p_battle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Battle % not found', p_battle_id;
    END IF;

    IF v_battle.defender_planet_id IS NULL THEN
        RETURN;
    END IF;

    FOR v_loss IN
        SELECT l.unit_id, l.destroyed_quantity
        FROM public.calculate_combat_defense_losses(p_battle_id) l
        WHERE l.side = 'DEFENDER'
          AND l.destroyed_quantity > 0
    LOOP
        IF EXISTS (
            SELECT 1
            FROM public.combat_defense_repairs r
            WHERE r.battle_id = p_battle_id
              AND r.defense_id = v_loss.unit_id
        ) THEN
            CONTINUE;
        END IF;

        SELECT count(*)::bigint
        INTO v_repaired
        FROM generate_series(1, v_loss.destroyed_quantity) g
        WHERE random() < 0.70;

        INSERT INTO public.combat_defense_repairs (
            battle_id, planet_id, defense_id,
            destroyed_quantity, repaired_quantity
        )
        VALUES (
            p_battle_id,
            v_battle.defender_planet_id,
            v_loss.unit_id,
            v_loss.destroyed_quantity,
            v_repaired
        );

        INSERT INTO public.planet_defenses (planet_id, defense_id, quantity)
        VALUES (v_battle.defender_planet_id, v_loss.unit_id, v_repaired)
        ON CONFLICT (planet_id, defense_id)
        DO UPDATE SET
            quantity = public.planet_defenses.quantity + EXCLUDED.quantity,
            updated_at = now();

        defense_id := v_loss.unit_id;
        destroyed_quantity := v_loss.destroyed_quantity;
        repaired_quantity := v_repaired;
        RETURN NEXT;
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.repair_defenses_after_combat(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repair_defenses_after_combat(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.resolve_attack_arrival(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

    -- OGame-style defense recovery: 70% chance per destroyed defense.
    PERFORM * FROM public.repair_defenses_after_combat(v_battle_id);

    PERFORM public.create_combat_debris(v_battle_id);

    v_duration := v_fleet.arrives_at - v_fleet.started_at;

    IF v_fleet.status = 'ARRIVED' THEN
        UPDATE public.fleet_movements
        SET status = 'RETURNING',
            returns_at = arrives_at + v_duration
        WHERE id = p_fleet_id;
    END IF;

    RETURN v_battle_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_attack_arrival(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_attack_arrival(uuid) TO service_role;