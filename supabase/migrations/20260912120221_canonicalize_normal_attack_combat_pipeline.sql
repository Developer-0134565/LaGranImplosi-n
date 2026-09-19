CREATE UNIQUE INDEX IF NOT EXISTS ux_combat_battles_one_per_fleet
ON public.combat_battles (fleet_id);

CREATE OR REPLACE FUNCTION public.resolve_combat(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $function$
DECLARE
    v_battle_id uuid;
    v_fleet public.fleet_movements%ROWTYPE;
    v_attacker_units bigint := 0;
    v_defender_units bigint := 0;
    v_defense_units bigint := 0;
    v_attacker_attack numeric := 0;
    v_attacker_shield numeric := 0;
    v_attacker_hull numeric := 0;
    v_defender_attack numeric := 0;
    v_defender_shield numeric := 0;
    v_defender_hull numeric := 0;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id=p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fleet % no existe',p_fleet_id;
    END IF;

    IF v_fleet.mission_type <> 'ATTACK' THEN
        RAISE EXCEPTION 'Fleet % no es una misión ATTACK',p_fleet_id;
    END IF;

    IF v_fleet.destination_planet_id IS NULL THEN
        RAISE EXCEPTION 'La flota % no tiene planeta objetivo',p_fleet_id;
    END IF;

    SELECT cb.id INTO v_battle_id
    FROM public.combat_battles cb
    WHERE cb.fleet_id=p_fleet_id
    ORDER BY cb.created_at
    LIMIT 1
    FOR UPDATE;

    IF v_battle_id IS NOT NULL THEN
        RETURN v_battle_id;
    END IF;

    SELECT
        COALESCE(SUM(sd.attack*fms.quantity),0),
        COALESCE(SUM(sd.shield*fms.quantity),0),
        COALESCE(SUM(sd.hull*fms.quantity),0),
        COALESCE(SUM(fms.quantity),0)
    INTO v_attacker_attack,v_attacker_shield,v_attacker_hull,v_attacker_units
    FROM public.fleet_movement_ships fms
    JOIN public.ship_definitions sd ON sd.id=fms.ship_id
    WHERE fms.fleet_id=p_fleet_id;

    IF v_attacker_units<=0 THEN
        RAISE EXCEPTION 'La flota % no contiene naves',p_fleet_id;
    END IF;

    SELECT
        COALESCE(SUM(sd.attack*ps.quantity),0),
        COALESCE(SUM(sd.shield*ps.quantity),0),
        COALESCE(SUM(sd.hull*ps.quantity),0),
        COALESCE(SUM(ps.quantity),0)
    INTO v_defender_attack,v_defender_shield,v_defender_hull,v_defender_units
    FROM public.planet_ships ps
    JOIN public.ship_definitions sd ON sd.id=ps.ship_id
    WHERE ps.planet_id=v_fleet.destination_planet_id
      AND ps.quantity>0;

    SELECT
        COALESCE(SUM(dd.attack*pd.quantity),0),
        COALESCE(SUM(dd.shield*pd.quantity),0),
        COALESCE(SUM(dd.hull*pd.quantity),0),
        COALESCE(SUM(pd.quantity),0)
    INTO v_defender_attack,v_defender_shield,v_defender_hull,v_defense_units
    FROM public.planet_defenses pd
    JOIN public.defense_definitions dd ON dd.id=pd.defense_id
    WHERE pd.planet_id=v_fleet.destination_planet_id
      AND pd.quantity>0;

    v_defender_units := v_defender_units + v_defense_units;

    INSERT INTO public.combat_battles(
        fleet_id,attacker_player_id,defender_planet_id,
        attacker_ships_before,attacker_ships_after,
        defender_ships_before,defender_ships_after,
        defender_defenses_before,defender_defenses_after,
        defender_combat_units_before,defender_combat_units_after
    ) VALUES (
        p_fleet_id,v_fleet.player_id,v_fleet.destination_planet_id,
        v_attacker_units,v_attacker_units,
        v_defender_units-v_defense_units,v_defender_units-v_defense_units,
        v_defense_units,v_defense_units,
        v_defender_units,v_defender_units
    ) RETURNING id INTO v_battle_id;

    PERFORM public.initialize_individual_combat_units(v_battle_id);

    RETURN v_battle_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_attack_arrival(p_fleet_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $function$
DECLARE
    v_fleet public.fleet_movements%ROWTYPE;
    v_battle_id uuid;
    v_last_round integer;
    v_duration interval;
    v_attacker_count bigint;
    v_defender_count bigint;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id=p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Fleet % no existe',p_fleet_id;
    END IF;

    IF v_fleet.mission_type <> 'ATTACK' THEN
        RAISE EXCEPTION 'Fleet % no es ATTACK',p_fleet_id;
    END IF;

    IF v_fleet.status NOT IN ('ARRIVED','RETURNING','COMPLETED') THEN
        RAISE EXCEPTION 'Fleet % no está lista para resolver ataque. Estado: %',p_fleet_id,v_fleet.status;
    END IF;

    SELECT cb.id, max(cr.round_number)
    INTO v_battle_id,v_last_round
    FROM public.combat_battles cb
    LEFT JOIN public.combat_rounds cr ON cr.battle_id=cb.id
    WHERE cb.fleet_id=p_fleet_id
    GROUP BY cb.id
    ORDER BY cb.created_at
    LIMIT 1;

    IF v_battle_id IS NULL THEN
        v_battle_id := public.resolve_combat(p_fleet_id);
    END IF;

    SELECT max(cr.round_number) INTO v_last_round
    FROM public.combat_rounds cr
    WHERE cr.battle_id=v_battle_id;

    IF NOT EXISTS (
        SELECT 1 FROM public.combat_battles cb
        WHERE cb.id=v_battle_id AND cb.finished_at IS NOT NULL
    ) THEN
        PERFORM public.run_expedition_combat(v_battle_id);
    END IF;

    SELECT max(cr.round_number) INTO v_last_round
    FROM public.combat_rounds cr
    WHERE cr.battle_id=v_battle_id;

    IF v_last_round IS NULL THEN
        RAISE EXCEPTION 'Battle % finished without rounds',v_battle_id;
    END IF;

    DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id;

    INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
    SELECT p_fleet_id,ciu.unit_id,count(*)::bigint
    FROM public.combat_individual_units ciu
    WHERE ciu.battle_id=v_battle_id
      AND ciu.round_number=v_last_round
      AND ciu.side='ATTACKER'
      AND ciu.unit_type='SHIP'
      AND ciu.alive=true
    GROUP BY ciu.unit_id;

    UPDATE public.planet_ships ps
    SET quantity=COALESCE(src.quantity,0)
    FROM (
        SELECT ciu.unit_id, count(*)::bigint quantity
        FROM public.combat_individual_units ciu
        WHERE ciu.battle_id=v_battle_id
          AND ciu.round_number=v_last_round
          AND ciu.side='DEFENDER'
          AND ciu.unit_type='SHIP'
          AND ciu.alive=true
        GROUP BY ciu.unit_id
    ) src
    WHERE ps.planet_id=v_fleet.destination_planet_id
      AND ps.ship_id=src.unit_id;

    UPDATE public.planet_ships ps
    SET quantity=0
    WHERE ps.planet_id=v_fleet.destination_planet_id
      AND EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id=v_battle_id
            AND ciu.round_number=v_last_round
            AND ciu.side='DEFENDER'
            AND ciu.unit_type='SHIP'
            AND ciu.unit_id=ps.ship_id
      )
      AND NOT EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id=v_battle_id
            AND ciu.round_number=v_last_round
            AND ciu.side='DEFENDER'
            AND ciu.unit_type='SHIP'
            AND ciu.unit_id=ps.ship_id
            AND ciu.alive=true
      );

    UPDATE public.planet_defenses pd
    SET quantity=COALESCE(src.quantity,0)
    FROM (
        SELECT ciu.unit_id, count(*)::bigint quantity
        FROM public.combat_individual_units ciu
        WHERE ciu.battle_id=v_battle_id
          AND ciu.round_number=v_last_round
          AND ciu.side='DEFENDER'
          AND ciu.unit_type='DEFENSE'
          AND ciu.alive=true
        GROUP BY ciu.unit_id
    ) src
    WHERE pd.planet_id=v_fleet.destination_planet_id
      AND pd.defense_id=src.unit_id;

    UPDATE public.planet_defenses pd
    SET quantity=0
    WHERE pd.planet_id=v_fleet.destination_planet_id
      AND EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id=v_battle_id
            AND ciu.round_number=v_last_round
            AND ciu.side='DEFENDER'
            AND ciu.unit_type='DEFENSE'
            AND ciu.unit_id=pd.defense_id
      )
      AND NOT EXISTS (
          SELECT 1 FROM public.combat_individual_units ciu
          WHERE ciu.battle_id=v_battle_id
            AND ciu.round_number=v_last_round
            AND ciu.side='DEFENDER'
            AND ciu.unit_type='DEFENSE'
            AND ciu.unit_id=pd.defense_id
            AND ciu.alive=true
      );

    PERFORM public.create_combat_debris(v_battle_id);

    v_duration := v_fleet.arrives_at-v_fleet.started_at;

    IF v_fleet.status='ARRIVED' THEN
        UPDATE public.fleet_movements
        SET status='RETURNING',returns_at=arrives_at+v_duration
        WHERE id=p_fleet_id;
    END IF;

    RETURN v_battle_id;
END;
$function$;