CREATE OR REPLACE FUNCTION public.run_expedition_combat(p_battle_id uuid)
RETURNS TABLE(rounds_played integer, attacker_alive bigint, defender_alive bigint, battle_result text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    r integer := 1;
    aa bigint := 0;
    dd bigint := 0;
    result text;
    v_round record;
BEGIN
    -- El worker ejecuta esta función dentro de resolve_expedition_arrival().
    -- No usamos SELECT sobre el resultado de process_combat_round_v2,
    -- porque su contrato de TABLE puede interactuar mal con PERFORM
    -- cuando el contexto ya está dentro de otra función SECURITY DEFINER.
    -- Consumimos explícitamente todas las columnas devueltas.
    PERFORM *
    FROM public.create_combat_round_snapshot(p_battle_id, 1);

    WHILE r <= 6 LOOP
        SELECT *
        INTO v_round
        FROM public.process_combat_round_v2(p_battle_id, r);

        aa := COALESCE(v_round.attacker_alive, 0);
        dd := COALESCE(v_round.defender_alive, 0);

        EXIT WHEN aa = 0 OR dd = 0 OR v_round.battle_result <> 'CONTINUE';

        r := r + 1;
    END LOOP;

    IF aa > 0 AND dd = 0 THEN
        result := 'ATTACKER_WIN';
    ELSIF aa = 0 AND dd > 0 THEN
        result := 'DEFENDER_WIN';
    ELSE
        result := 'DRAW';
    END IF;

    UPDATE public.combat_battles
    SET
        finished_at = COALESCE(finished_at, clock_timestamp()),
        attacker_win = (result = 'ATTACKER_WIN'),
        defender_win = (result = 'DEFENDER_WIN'),
        draw = (result = 'DRAW'),
        attacker_ships_after = aa,
        defender_ships_after = dd
    WHERE id = p_battle_id;

    RETURN QUERY
    SELECT r, aa, dd, result;
END;
$function$;