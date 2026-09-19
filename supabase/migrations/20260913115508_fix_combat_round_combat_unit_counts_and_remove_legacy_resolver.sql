CREATE OR REPLACE FUNCTION public.process_combat_round_v2(p_battle_id uuid, p_round_number integer)
RETURNS TABLE(battle_id uuid, round_number integer, attacker_alive bigint, defender_alive bigint, battle_result text, next_round integer, shots_created integer, damage_rows integer, units_updated integer, units_destroyed integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_snapshot_count integer;
    v_shots_created integer := 0;
    v_damage_rows integer := 0;
    v_units_updated integer := 0;
    v_units_destroyed integer := 0;
    v_result record;
    v_apply record;
    v_explosion record;
    v_target record;
    v_attacker_attack numeric := 0;
    v_attacker_shield numeric := 0;
    v_attacker_hull numeric := 0;
    v_defender_attack numeric := 0;
    v_defender_shield numeric := 0;
    v_defender_hull numeric := 0;
    v_attacker_before bigint := 0;
    v_attacker_after bigint := 0;
    v_defender_before bigint := 0;
    v_defender_after bigint := 0;
    v_defender_combat_before bigint := 0;
    v_defender_combat_after bigint := 0;
BEGIN
    IF p_round_number < 1 OR p_round_number > 6 THEN
        RAISE EXCEPTION 'Invalid combat round: %', p_round_number;
    END IF;

    IF EXISTS (SELECT 1 FROM public.combat_rounds cr WHERE cr.battle_id=p_battle_id AND cr.round_number=p_round_number) THEN
        RAISE EXCEPTION 'Combat round % for battle % is already closed', p_round_number, p_battle_id;
    END IF;

    SELECT COUNT(*) INTO v_snapshot_count
    FROM public.combat_round_snapshot_units crsu
    WHERE crsu.battle_id=p_battle_id AND crsu.round_number=p_round_number;

    IF v_snapshot_count=0 THEN
        PERFORM * FROM public.create_combat_round_snapshot(p_battle_id,p_round_number);
    END IF;

    SELECT COUNT(*) INTO v_shots_created
    FROM public.combat_shots cs
    WHERE cs.battle_id=p_battle_id AND cs.round_number=p_round_number;

    IF v_shots_created=0 THEN
        PERFORM * FROM public.generate_combat_round_v2(p_battle_id,p_round_number);
    END IF;

    PERFORM * FROM public.expand_all_rapidfire_v2(p_battle_id,p_round_number);

    SELECT COUNT(*) INTO v_damage_rows
    FROM public.combat_round_damage crd
    WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number;

    IF v_damage_rows=0 THEN
        PERFORM * FROM public.calculate_combat_round_pending_damage(p_battle_id,p_round_number);
    END IF;

    FOR v_target IN
        SELECT DISTINCT crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
        FROM public.combat_round_damage crd
        WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number
        ORDER BY crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
    LOOP
        PERFORM * FROM public.resolve_pending_target_damage(
            p_battle_id,p_round_number,v_target.target_side,v_target.target_unit_type,
            v_target.target_unit_id,v_target.target_unit_number
        );
    END LOOP;

    SELECT * INTO v_apply FROM public.apply_combat_round_damage(p_battle_id,p_round_number);
    v_units_updated:=COALESCE(v_apply.units_updated,0);

    FOR v_explosion IN SELECT * FROM public.resolve_combat_round_explosions(p_battle_id,p_round_number)
    LOOP
        IF v_explosion.exploded THEN v_units_destroyed:=v_units_destroyed+1; END IF;
    END LOOP;

    SELECT * INTO v_result FROM public.finish_combat_round_v1(p_battle_id,p_round_number);

    SELECT
        COALESCE(SUM(CASE WHEN crsu.side='ATTACKER' THEN crsu.attack ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN crsu.side='ATTACKER' THEN crsu.shield_start ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN crsu.side='ATTACKER' THEN crsu.hull_start ELSE 0 END),0),
        COUNT(*) FILTER (WHERE crsu.side='ATTACKER')
    INTO v_attacker_attack,v_attacker_shield,v_attacker_hull,v_attacker_before
    FROM public.combat_round_snapshot_units crsu
    WHERE crsu.battle_id=p_battle_id AND crsu.round_number=p_round_number;

    SELECT
        COALESCE(SUM(CASE WHEN crsu.side='DEFENDER' AND crsu.unit_type='SHIP' THEN crsu.attack ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN crsu.side='DEFENDER' AND crsu.unit_type='SHIP' THEN crsu.shield_start ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN crsu.side='DEFENDER' AND crsu.unit_type='SHIP' THEN crsu.hull_start ELSE 0 END),0),
        COUNT(*) FILTER (WHERE crsu.side='DEFENDER' AND crsu.unit_type='SHIP'),
        COUNT(*) FILTER (WHERE crsu.side='DEFENDER')
    INTO v_defender_attack,v_defender_shield,v_defender_hull,v_defender_before,v_defender_combat_before
    FROM public.combat_round_snapshot_units crsu
    WHERE crsu.battle_id=p_battle_id AND crsu.round_number=p_round_number;

    SELECT
        COUNT(*) FILTER (WHERE cui.side='ATTACKER' AND cui.alive=true),
        COUNT(*) FILTER (WHERE cui.side='DEFENDER' AND cui.unit_type='SHIP' AND cui.alive=true),
        COUNT(*) FILTER (WHERE cui.side='DEFENDER' AND cui.alive=true)
    INTO v_attacker_after,v_defender_after,v_defender_combat_after
    FROM public.combat_individual_units cui
    WHERE cui.battle_id=p_battle_id AND cui.round_number=p_round_number;

    INSERT INTO public.combat_rounds(
        battle_id,round_number,attacker_attack,attacker_shield,attacker_hull,
        defender_attack,defender_shield,defender_hull,
        attacker_units_before,attacker_units_after,defender_units_before,defender_units_after,
        defender_combat_units_before,defender_combat_units_after
    ) VALUES (
        p_battle_id,p_round_number,v_attacker_attack,v_attacker_shield,v_attacker_hull,
        v_defender_attack,v_defender_shield,v_defender_hull,
        v_attacker_before,v_attacker_after,v_defender_before,v_defender_after,
        v_defender_combat_before,v_defender_combat_after
    );

    IF v_result.battle_result='CONTINUE' AND v_result.next_round IS NOT NULL AND v_result.next_round<=6 THEN
        PERFORM * FROM public.create_combat_next_round(p_battle_id,p_round_number);
        PERFORM * FROM public.create_combat_round_snapshot(p_battle_id,v_result.next_round);
    END IF;

    RETURN QUERY SELECT p_battle_id,p_round_number,v_result.attacker_alive::bigint,v_result.defender_alive::bigint,
        v_result.battle_result::text,v_result.next_round::integer,
        (SELECT COUNT(*)::integer FROM public.combat_shots cs2 WHERE cs2.battle_id=p_battle_id AND cs2.round_number=p_round_number),
        (SELECT COUNT(*)::integer FROM public.combat_round_damage crd2 WHERE crd2.battle_id=p_battle_id AND crd2.round_number=p_round_number),
        v_units_updated,v_units_destroyed;
END;
$function$;

UPDATE public.combat_rounds cr
SET defender_combat_units_before=(
        SELECT COUNT(*) FROM public.combat_round_snapshot_units s
        WHERE s.battle_id=cr.battle_id AND s.round_number=cr.round_number AND s.side='DEFENDER'
    ),
    defender_combat_units_after=(
        SELECT COUNT(*) FROM public.combat_individual_units u
        WHERE u.battle_id=cr.battle_id AND u.round_number=cr.round_number AND u.side='DEFENDER' AND u.alive=true
    );

DROP FUNCTION IF EXISTS public.resolve_combat_round(uuid);