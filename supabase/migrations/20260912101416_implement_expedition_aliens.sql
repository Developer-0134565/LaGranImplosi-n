CREATE OR REPLACE FUNCTION public.resolve_expedition_aliens(p_fleet_id uuid)
RETURNS TABLE(battle_id uuid, result text, enemy_ships jsonb, survivors jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_fleet public.fleet_movements%ROWTYPE;
    v_battle_id uuid;
    v_player_id uuid;
    v_universe_id uuid;
    v_origin_planet_id uuid;
    v_ship record;
    v_qty bigint;
    v_total_units bigint := 0;
    v_adapted bigint;
    v_fixed_ship text;
    v_fixed_qty bigint;
    v_roll numeric;
    v_strength numeric;
    v_attacker_tech integer;
    v_alien_tech integer;
    v_enemy jsonb := '{}'::jsonb;
    v_survivors jsonb := '{}'::jsonb;
    v_result text;
BEGIN
    SELECT * INTO v_fleet
    FROM public.fleet_movements
    WHERE id = p_fleet_id AND mission_type = 'EXPEDITION'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id;
    END IF;

    IF v_fleet.status <> 'OUTBOUND' THEN
        SELECT er.battle_id, er.outcome, COALESCE(er.enemy_ships,'{}'::jsonb), COALESCE(er.ships,'{}'::jsonb)
        INTO battle_id, result, enemy_ships, survivors
        FROM public.expedition_results er
        WHERE er.fleet_id = p_fleet_id;
        IF FOUND THEN RETURN NEXT; RETURN; END IF;
        RAISE EXCEPTION 'Expedition fleet % is not OUTBOUND', p_fleet_id;
    END IF;

    SELECT p.player_id, p.universe_id, p.id
    INTO v_player_id, v_universe_id, v_origin_planet_id
    FROM public.planets p
    WHERE p.id = v_fleet.origin_planet_id;

    SELECT COALESCE(MAX(pr.level), 0) INTO v_attacker_tech
    FROM public.player_research pr
    JOIN public.research_definitions rd ON rd.id = pr.research_id
    WHERE pr.player_id = v_player_id
      AND rd.id IN ('weapons', 'shielding', 'armour');

    -- OGame rule: alien technology is three levels above the expedition player's technology.
    v_alien_tech := v_attacker_tech + 3;

    INSERT INTO public.combat_battles (
        player_id, origin_planet_id, destination_planet_id, mission_type,
        status, current_round, max_rounds
    )
    VALUES (
        v_player_id, v_origin_planet_id, NULL, 'EXPEDITION_ALIENS',
        'IN_PROGRESS', 0, 6
    )
    RETURNING id INTO v_battle_id;

    -- Copy expedition ships into the combat snapshot as the attacker.
    FOR v_ship IN
        SELECT fms.ship_id, fms.quantity
        FROM public.fleet_movement_ships fms
        WHERE fms.fleet_movement_id = p_fleet_id
          AND fms.quantity > 0
    LOOP
        INSERT INTO public.combat_individual_units (
            battle_id, side, unit_id, unit_number,
            shield_current, hull_current, alive
        )
        SELECT
            v_battle_id, 'ATTACKER', v_ship.ship_id, gs.n,
            sd.shield, sd.hull, true
        FROM public.ship_definitions sd
        CROSS JOIN generate_series(1, v_ship.quantity) gs(n)
        WHERE sd.id = v_ship.ship_id;
        v_total_units := v_total_units + v_ship.quantity;
    END LOOP;

    -- Alien configuration: 89/10/1 with 34-46%, 54-66%, 81-99% adapted strength.
    v_roll := random() * 100;
    IF v_roll < 89 THEN
        v_strength := 0.34 + random() * 0.12;
        v_fixed_ship := 'heavy_fighter';
        v_fixed_qty := 5;
    ELSIF v_roll < 99 THEN
        v_strength := 0.54 + random() * 0.12;
        v_fixed_ship := 'battlecruiser';
        v_fixed_qty := 3;
    ELSE
        v_strength := 0.81 + random() * 0.18;
        v_fixed_ship := 'destroyer';
        v_fixed_qty := 2;
    END IF;

    v_adapted := greatest(1, floor(v_total_units * v_strength));

    INSERT INTO public.combat_individual_units (
        battle_id, side, unit_id, unit_number,
        shield_current, hull_current, alive
    )
    SELECT
        v_battle_id, 'DEFENDER', v_ship.ship_id, gs.n,
        round(sd.shield * (1 + (v_alien_tech * 0.10))),
        round(sd.hull * (1 + (v_alien_tech * 0.10))), true
    FROM public.ship_definitions sd
    CROSS JOIN generate_series(1, v_adapted) gs(n)
    WHERE sd.id = (
        SELECT fms.ship_id
        FROM public.fleet_movement_ships fms
        WHERE fms.fleet_movement_id = p_fleet_id
        ORDER BY fms.quantity DESC, fms.ship_id
        LIMIT 1
    );

    INSERT INTO public.combat_individual_units (
        battle_id, side, unit_id, unit_number,
        shield_current, hull_current, alive
    )
    SELECT
        v_battle_id, 'DEFENDER', v_fixed_ship, gs.n,
        round(sd.shield * (1 + (v_alien_tech * 0.10))),
        round(sd.hull * (1 + (v_alien_tech * 0.10))), true
    FROM public.ship_definitions sd
    CROSS JOIN generate_series(1, v_fixed_qty) gs(n)
    WHERE sd.id = v_fixed_ship;

    SELECT COALESCE(jsonb_object_agg(unit_id, qty), '{}'::jsonb)
    INTO v_enemy
    FROM (
        SELECT unit_id, count(*) qty
        FROM public.combat_individual_units
        WHERE battle_id = v_battle_id AND side = 'DEFENDER' AND alive
        GROUP BY unit_id
    ) x;

    INSERT INTO public.expedition_results (
        fleet_id, player_id, outcome, ships, battle_id,
        resolved_at, enemy_ships, event_type
    ) VALUES (
        p_fleet_id, v_player_id, 'ALIENS', '{}'::jsonb, v_battle_id,
        now(), v_enemy, 'ALIENS'
    )
    ON CONFLICT (fleet_id) DO UPDATE SET
        outcome = EXCLUDED.outcome,
        battle_id = EXCLUDED.battle_id,
        enemy_ships = EXCLUDED.enemy_ships,
        resolved_at = EXCLUDED.resolved_at;

    -- Combat execution is owned by the resolver, preventing the worker from running it twice.
    PERFORM public.run_expedition_combat(v_battle_id);

    SELECT COALESCE(jsonb_object_agg(unit_id, qty), '{}'::jsonb)
    INTO v_survivors
    FROM (
        SELECT unit_id, count(*) qty
        FROM public.combat_individual_units
        WHERE battle_id = v_battle_id AND side = 'ATTACKER' AND alive
        GROUP BY unit_id
    ) x;

    UPDATE public.expedition_results
    SET ships = v_survivors
    WHERE fleet_id = p_fleet_id;

    SELECT cb.status INTO v_result
    FROM public.combat_battles cb
    WHERE cb.id = v_battle_id;

    battle_id := v_battle_id;
    result := v_result;
    enemy_ships := v_enemy;
    survivors := v_survivors;
    RETURN NEXT;
END;
$function$;