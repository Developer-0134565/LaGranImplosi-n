CREATE OR REPLACE FUNCTION public.resolve_expedition_pirates(p_fleet_id uuid)
RETURNS TABLE(
    battle_id uuid,
    battle_result text,
    enemy_ships jsonb,
    surviving_ships jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_fleet RECORD;
    v_battle_id uuid;
    v_origin_planet uuid;
    v_player_id uuid;
    v_tier_roll integer;
    v_strength numeric;
    v_fixed_ship text;
    v_fixed_qty integer;
    v_weapon_level integer;
    v_shield_level integer;
    v_armour_level integer;
    v_pirate_weapon integer;
    v_pirate_shield integer;
    v_pirate_armour integer;
    v_attacker_units bigint := 0;
    v_defender_units bigint := 0;
    v_attacker_before bigint := 0;
    v_defender_before bigint := 0;
    v_round integer;
    v_round_result RECORD;
    v_final_result text;
    v_enemy jsonb := '{}'::jsonb;
    v_survivors jsonb := '{}'::jsonb;
    v_ship RECORD;
    v_qty bigint;
    v_structural_total numeric;
    v_target_structural numeric;
    v_adapted_structural numeric := 0;
    v_unit_qty bigint;
    v_unit_number integer;
    v_attack numeric;
    v_shield numeric;
    v_hull numeric;
BEGIN
    SELECT fm.*
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
      AND fm.mission_type = 'EXPEDITION'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id;
    END IF;

    v_origin_planet := v_fleet.origin_planet_id;
    v_player_id := v_fleet.player_id;

    IF EXISTS (
        SELECT 1
        FROM public.fleet_movement_ships
        WHERE fleet_id = p_fleet_id
          AND ship_id = 'deathstar'
          AND quantity > 0
    ) THEN
        RAISE EXCEPTION 'Deathstar expeditions cannot receive pirate combat';
    END IF;

    SELECT COALESCE(pr.level, 0) INTO v_weapon_level
    FROM public.research_definitions rd
    LEFT JOIN public.player_research pr
      ON pr.research_id = rd.id
     AND pr.player_id = v_player_id
    WHERE rd.id = 'weapons_technology';

    SELECT COALESCE(pr.level, 0) INTO v_shield_level
    FROM public.research_definitions rd
    LEFT JOIN public.player_research pr
      ON pr.research_id = rd.id
     AND pr.player_id = v_player_id
    WHERE rd.id = 'shielding_technology';

    SELECT COALESCE(pr.level, 0) INTO v_armour_level
    FROM public.research_definitions rd
    LEFT JOIN public.player_research pr
      ON pr.research_id = rd.id
     AND pr.player_id = v_player_id
    WHERE rd.id = 'armour_technology';

    v_pirate_weapon := greatest(v_weapon_level - 3, 3);
    v_pirate_shield := greatest(v_shield_level - 3, 3);
    v_pirate_armour := greatest(v_armour_level - 3, 3);

    -- OGame expedition combat variants: 89% normal, 10% strong, 1% very strong.
    v_tier_roll := floor(random() * 100) + 1;

    IF v_tier_roll <= 89 THEN
        v_strength := 0.27 + random() * 0.06;
        v_fixed_ship := 'light_fighter';
        v_fixed_qty := 5;
    ELSIF v_tier_roll <= 99 THEN
        v_strength := 0.45 + random() * 0.10;
        v_fixed_ship := 'cruiser';
        v_fixed_qty := 3;
    ELSE
        v_strength := 0.72 + random() * 0.16;
        v_fixed_ship := 'battleship';
        v_fixed_qty := 2;
    END IF;

    SELECT COALESCE(SUM(
        (sd.base_metal + sd.base_crystal + sd.base_deuterium) * fms.quantity
    ), 0)
    INTO v_structural_total
    FROM public.fleet_movement_ships fms
    JOIN public.ship_definitions sd ON sd.id = fms.ship_id
    WHERE fms.fleet_id = p_fleet_id
      AND fms.ship_id NOT IN ('recycler','colony_ship','deathstar','espionage_probe');

    v_target_structural := v_structural_total * v_strength;

    -- Create one auditable combat battle. NPCs are represented as DEFENDER units,
    -- so the existing 6-round combat engine can be reused unchanged.
    INSERT INTO public.combat_battles (
        fleet_id,
        attacker_player_id,
        defender_planet_id,
        attacker_ships_before,
        attacker_ships_after,
        defender_ships_before,
        defender_ships_after,
        defender_defenses_before,
        defender_defenses_after,
        defender_combat_units_before,
        defender_combat_units_after,
        started_at
    )
    VALUES (
        p_fleet_id,
        v_player_id,
        v_origin_planet,
        0,0,0,0,0,0,0,0,
        clock_timestamp()
    )
    RETURNING id INTO v_battle_id;

    -- Player expedition fleet = ATTACKER.
    FOR v_ship IN
        SELECT fms.ship_id, fms.quantity, sd.attack, sd.shield, sd.hull
        FROM public.fleet_movement_ships fms
        JOIN public.ship_definitions sd ON sd.id = fms.ship_id
        WHERE fms.fleet_id = p_fleet_id
          AND fms.quantity > 0
    LOOP
        v_attack := v_ship.attack * (1 + (v_weapon_level * 0.10));
        v_shield := v_ship.shield * (1 + (v_shield_level * 0.10));
        v_hull := v_ship.hull * (1 + (v_armour_level * 0.10));

        FOR v_unit_number IN 1..v_ship.quantity LOOP
            INSERT INTO public.combat_individual_units (
                battle_id, round_number, side, unit_type, unit_id,
                unit_number, attack, shield_max, shield_current,
                structural_integrity, hull_max, hull_current, alive
            ) VALUES (
                v_battle_id, 1, 'ATTACKER', 'SHIP', v_ship.ship_id,
                v_unit_number, v_attack, v_shield, v_shield,
                v_hull, v_hull, v_hull, true
            );
            v_attacker_units := v_attacker_units + 1;
        END LOOP;
    END LOOP;

    -- Adapted enemy composition: preserve the player's fleet mix by structural value.
    FOR v_ship IN
        SELECT fms.ship_id, fms.quantity, sd.base_metal, sd.base_crystal,
               sd.base_deuterium, sd.attack, sd.shield, sd.hull
        FROM public.fleet_movement_ships fms
        JOIN public.ship_definitions sd ON sd.id = fms.ship_id
        WHERE fms.fleet_id = p_fleet_id
          AND fms.quantity > 0
          AND fms.ship_id NOT IN ('recycler','colony_ship','deathstar','espionage_probe')
    LOOP
        v_unit_qty := floor(v_ship.quantity * v_strength);
        IF v_unit_qty > 0 THEN
            v_attack := v_ship.attack * (1 + (v_pirate_weapon * 0.10));
            v_shield := v_ship.shield * (1 + (v_pirate_shield * 0.10));
            v_hull := v_ship.hull * (1 + (v_pirate_armour * 0.10));

            FOR v_unit_number IN 1..v_unit_qty LOOP
                INSERT INTO public.combat_individual_units (
                    battle_id, round_number, side, unit_type, unit_id,
                    unit_number, attack, shield_max, shield_current,
                    structural_integrity, hull_max, hull_current, alive
                ) VALUES (
                    v_battle_id, 1, 'DEFENDER', 'SHIP', v_ship.ship_id,
                    v_unit_number, v_attack, v_shield, v_shield,
                    v_hull, v_hull, v_hull, true
                );
                v_defender_units := v_defender_units + 1;
            END LOOP;

            v_adapted_structural := v_adapted_structural
                + (v_ship.base_metal + v_ship.base_crystal + v_ship.base_deuterium) * v_unit_qty;
        END IF;
    END LOOP;

    -- Fixed pirate component.
    SELECT sd.attack, sd.shield, sd.hull
    INTO v_attack, v_shield, v_hull
    FROM public.ship_definitions sd
    WHERE sd.id = v_fixed_ship;

    v_attack := v_attack * (1 + (v_pirate_weapon * 0.10));
    v_shield := v_shield * (1 + (v_pirate_shield * 0.10));
    v_hull := v_hull * (1 + (v_pirate_armour * 0.10));

    FOR v_unit_number IN 1..v_fixed_qty LOOP
        INSERT INTO public.combat_individual_units (
            battle_id, round_number, side, unit_type, unit_id,
            unit_number, attack, shield_max, shield_current,
            structural_integrity, hull_max, hull_current, alive
        ) VALUES (
            v_battle_id, 1, 'DEFENDER', 'SHIP', v_fixed_ship,
            100000 + v_unit_number, v_attack, v_shield, v_shield,
            v_hull, v_hull, v_hull, true
        );
        v_defender_units := v_defender_units + 1;
    END LOOP;

    v_attacker_before := v_attacker_units;
    v_defender_before := v_defender_units;

    UPDATE public.combat_battles
    SET attacker_ships_before = v_attacker_before,
        attacker_ships_after = v_attacker_before,
        defender_ships_before = v_defender_before,
        defender_ships_after = v_defender_before,
        defender_defenses_before = 0,
        defender_defenses_after = 0,
        defender_combat_units_before = v_defender_before,
        defender_combat_units_after = v_defender_before
    WHERE id = v_battle_id;

    -- Build an auditable enemy manifest before combat starts.
    SELECT COALESCE(jsonb_object_agg(unit_id, quantity), '{}'::jsonb)
    INTO v_enemy
    FROM (
        SELECT unit_id, count(*)::bigint AS quantity
        FROM public.combat_individual_units
        WHERE battle_id = v_battle_id
          AND side = 'DEFENDER'
        GROUP BY unit_id
    ) q;

    -- Resolve up to six combat rounds using the existing combat engine.
    v_round := 1;
    LOOP
        SELECT * INTO v_round_result
        FROM public.process_combat_round_v2(v_battle_id, v_round);

        IF v_round_result.battle_result IN ('ATTACKER_WIN','DEFENDER_WIN','DRAW') THEN
            v_final_result := v_round_result.battle_result;
            EXIT;
        END IF;

        IF v_round >= 6 OR v_round_result.next_round IS NULL THEN
            v_final_result := 'DRAW';
            EXIT;
        END IF;

        v_round := v_round_result.next_round;
    END LOOP;

    PERFORM public.finish_combat_battle(v_battle_id);

    -- Persist surviving expedition ships back into fleet_movement_ships.
    DELETE FROM public.fleet_movement_ships WHERE fleet_id = p_fleet_id;

    INSERT INTO public.fleet_movement_ships (fleet_id, ship_id, quantity)
    SELECT p_fleet_id, unit_id, count(*)::bigint
    FROM public.combat_individual_units
    WHERE battle_id = v_battle_id
      AND round_number = v_round
      AND side = 'ATTACKER'
      AND alive = true
    GROUP BY unit_id;

    SELECT COALESCE(jsonb_object_agg(ship_id, quantity), '{}'::jsonb)
    INTO v_survivors
    FROM public.fleet_movement_ships
    WHERE fleet_id = p_fleet_id;

    RETURN QUERY
    SELECT v_battle_id, v_final_result, v_enemy, v_survivors;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_expedition_arrival(p_fleet_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_fleet RECORD;
    v_universe_id uuid;
    v_outcome text;
    v_roll numeric;
    v_weight_total numeric;
    v_hold_seconds numeric := 0;
    v_delay_multiplier numeric := 1;
    v_speedup_percentage numeric := 0;
    v_speedup_seconds numeric := 0;
    v_flight_seconds numeric := 0;
    v_return_seconds numeric := 0;
    v_reward RECORD;
    v_ship_reward jsonb;
    v_ship_budget RECORD;
    v_ship_id text;
    v_ship_quantity bigint;
    v_battle RECORD;
BEGIN
    SELECT fm.id, fm.player_id, fm.origin_planet_id, fm.status,
           fm.mission_type, fm.started_at, fm.arrives_at
    INTO v_fleet
    FROM public.fleet_movements fm
    WHERE fm.id = p_fleet_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Fleet % not found', p_fleet_id; END IF;
    IF v_fleet.mission_type <> 'EXPEDITION' THEN RAISE EXCEPTION 'Fleet % is not an EXPEDITION', p_fleet_id; END IF;
    IF v_fleet.status <> 'ARRIVED' THEN RAISE EXCEPTION 'Expedition % must be ARRIVED before resolution', p_fleet_id; END IF;

    SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id = v_fleet.origin_planet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found for expedition %', p_fleet_id; END IF;

    v_flight_seconds := EXTRACT(EPOCH FROM (v_fleet.arrives_at - v_fleet.started_at));
    IF v_flight_seconds <= 0 THEN RAISE EXCEPTION 'Invalid expedition flight duration for fleet %', p_fleet_id; END IF;

    SELECT es.weight_ships + es.weight_resources + es.weight_delay + es.weight_speedup +
           es.weight_nothing + es.weight_black_hole + es.weight_pirates + es.weight_aliens +
           es.weight_dark_matter + es.weight_merchant + es.weight_items
    INTO v_weight_total
    FROM public.expedition_settings es
    WHERE es.universe_id = v_universe_id;

    IF v_weight_total IS NULL OR v_weight_total <= 0 THEN
        RAISE EXCEPTION 'Invalid expedition weights for universe %', v_universe_id;
    END IF;

    v_roll := random() * v_weight_total;
    v_outcome := public.select_expedition_outcome(v_universe_id, v_roll);

    IF v_outcome = 'PIRATES' THEN
        SELECT * INTO v_battle FROM public.resolve_expedition_pirates(p_fleet_id);

        INSERT INTO public.expedition_results (
            fleet_id, player_id, outcome, reward_tier, reward_multiplier,
            random_roll, weight_total, hold_seconds, delay_seconds, speedup_seconds,
            battle_id, enemy_ships, ships
        ) VALUES (
            p_fleet_id, v_fleet.player_id, 'PIRATES', NULL, 1,
            v_roll, v_weight_total, 0, 0, 0,
            v_battle.battle_id, v_battle.enemy_ships, v_battle.surviving_ships
        )
        ON CONFLICT (fleet_id) DO UPDATE SET
            outcome = EXCLUDED.outcome,
            reward_multiplier = EXCLUDED.reward_multiplier,
            random_roll = EXCLUDED.random_roll,
            weight_total = EXCLUDED.weight_total,
            battle_id = EXCLUDED.battle_id,
            enemy_ships = EXCLUDED.enemy_ships,
            ships = EXCLUDED.ships,
            resolved_at = clock_timestamp();

        UPDATE public.fleet_movements
        SET status = 'RETURNING',
            returns_at = v_fleet.arrives_at + make_interval(secs => v_flight_seconds)
        WHERE id = p_fleet_id;

        RETURN 'PIRATES';

    ELSIF v_outcome = 'SHIPS' THEN
        v_ship_reward := public.prepare_expedition_ship_reward_multitype(p_fleet_id);
        SELECT reward_tier, reward_multiplier, max_ship_find, scaled_ship_find, ship_reward
        INTO v_ship_budget FROM public.expedition_reward_budgets WHERE fleet_id = p_fleet_id FOR UPDATE;
        FOR v_ship_id, v_ship_quantity IN SELECT key, value::bigint FROM jsonb_each_text(v_ship_reward) LOOP
            IF v_ship_quantity > 0 THEN
                INSERT INTO public.fleet_movement_ships(fleet_id,ship_id,quantity)
                VALUES(p_fleet_id,v_ship_id,v_ship_quantity)
                ON CONFLICT(fleet_id,ship_id) DO UPDATE SET quantity=public.fleet_movement_ships.quantity+EXCLUDED.quantity;
            END IF;
        END LOOP;
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,ships)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_ship_budget.reward_tier,v_ship_budget.reward_multiplier,v_roll,v_weight_total,0,0,0,v_ship_reward)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,ships=EXCLUDED.ships,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'RESOURCES' THEN
        SELECT * INTO v_reward FROM public.prepare_expedition_resource_reward(p_fleet_id);
        UPDATE public.fleet_movements SET metal=CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END, crystal=CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END, deuterium=CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END WHERE id=p_fleet_id;
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_tier,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds,max_resource_find,scaled_resource_find,cargo_capacity,metal,crystal,deuterium)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_reward.reward_tier,v_reward.reward_multiplier,v_roll,v_weight_total,0,0,0,v_reward.max_resource_find,v_reward.scaled_resource_find,v_reward.cargo_capacity,CASE WHEN v_reward.resource_type='METAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='CRYSTAL' THEN v_reward.final_resource_amount ELSE 0 END,CASE WHEN v_reward.resource_type='DEUTERIUM' THEN v_reward.final_resource_amount ELSE 0 END)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_tier=EXCLUDED.reward_tier,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,max_resource_find=EXCLUDED.max_resource_find,scaled_resource_find=EXCLUDED.scaled_resource_find,cargo_capacity=EXCLUDED.cargo_capacity,metal=EXCLUDED.metal,crystal=EXCLUDED.crystal,deuterium=EXCLUDED.deuterium,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'DELAY' THEN
        v_delay_multiplier := public.select_expedition_delay_multiplier();
        v_hold_seconds := public.calculate_expedition_delay_seconds(p_fleet_id,v_delay_multiplier);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_delay_multiplier,v_roll,v_weight_total,v_hold_seconds,v_hold_seconds,0)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();

    ELSIF v_outcome = 'SPEEDUP' THEN
        v_speedup_percentage := public.select_expedition_speedup_percentage();
        v_speedup_seconds := public.calculate_expedition_speedup_seconds(p_fleet_id,v_speedup_percentage);
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,v_speedup_percentage,v_roll,v_weight_total,0,0,v_speedup_seconds)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();
        v_return_seconds := greatest(v_flight_seconds-v_speedup_seconds,1);
        UPDATE public.fleet_movements SET status='RETURNING',returns_at=v_fleet.arrives_at+make_interval(secs=>v_return_seconds) WHERE id=p_fleet_id;
        RETURN 'SPEEDUP';
    ELSE
        INSERT INTO public.expedition_results(fleet_id,player_id,outcome,reward_multiplier,random_roll,weight_total,hold_seconds,delay_seconds,speedup_seconds)
        VALUES(p_fleet_id,v_fleet.player_id,v_outcome,1,v_roll,v_weight_total,0,0,0)
        ON CONFLICT(fleet_id) DO UPDATE SET outcome=EXCLUDED.outcome,reward_multiplier=EXCLUDED.reward_multiplier,random_roll=EXCLUDED.random_roll,weight_total=EXCLUDED.weight_total,hold_seconds=EXCLUDED.hold_seconds,delay_seconds=EXCLUDED.delay_seconds,speedup_seconds=EXCLUDED.speedup_seconds,resolved_at=clock_timestamp();
    END IF;

    UPDATE public.fleet_movements
    SET status='RETURNING',
        returns_at=v_fleet.arrives_at+make_interval(secs=>(v_flight_seconds+v_hold_seconds))
    WHERE id=p_fleet_id;

    RETURN v_outcome;
END;
$function$;