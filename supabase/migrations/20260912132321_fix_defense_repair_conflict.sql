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
    v_existing boolean;
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
        SELECT EXISTS (
            SELECT 1
            FROM public.combat_defense_repairs r
            WHERE r.battle_id = p_battle_id
              AND r.defense_id = v_loss.unit_id
        ) INTO v_existing;

        IF v_existing THEN
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

        UPDATE public.planet_defenses pd
        SET quantity = pd.quantity + v_repaired,
            updated_at = now()
        WHERE pd.planet_id = v_battle.defender_planet_id
          AND pd.defense_id = v_loss.unit_id;

        IF NOT FOUND AND v_repaired > 0 THEN
            INSERT INTO public.planet_defenses (planet_id, defense_id, quantity)
            VALUES (v_battle.defender_planet_id, v_loss.unit_id, v_repaired);
        END IF;

        defense_id := v_loss.unit_id;
        destroyed_quantity := v_loss.destroyed_quantity;
        repaired_quantity := v_repaired;
        RETURN NEXT;
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.repair_defenses_after_combat(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repair_defenses_after_combat(uuid) TO service_role;