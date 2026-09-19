CREATE OR REPLACE FUNCTION public.resolve_pending_target_damage(p_battle_id uuid, p_round_number integer, p_target_side text, p_target_unit_type text, p_target_unit_id text, p_target_unit_number integer)
RETURNS TABLE(target_side text, target_unit_type text, target_unit_id text, target_unit_number integer, shots_resolved integer, shield_start numeric, shield_final numeric, hull_start numeric, hull_final numeric, total_shield_damage numeric, total_hull_damage numeric, total_damage numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_snapshot public.combat_round_snapshot_units%ROWTYPE;
  v_damage public.combat_round_damage%ROWTYPE;
  v_shield numeric;
  v_hull numeric;
  v_shield_before numeric;
  v_sd numeric;
  v_hd numeric;
  v_total numeric;
  v_bounced boolean;
  v_exploded boolean;
  v_shots integer:=0;
  v_tsd numeric:=0;
  v_thd numeric:=0;
BEGIN
  SELECT * INTO v_snapshot
  FROM public.combat_round_snapshot_units cru
  WHERE cru.battle_id=p_battle_id
    AND cru.round_number=p_round_number
    AND cru.side=p_target_side
    AND cru.unit_type=p_target_unit_type
    AND cru.unit_id=p_target_unit_id
    AND cru.unit_number=p_target_unit_number
    AND cru.alive_start
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target not found in combat snapshot: % / % / % / %',p_target_side,p_target_unit_type,p_target_unit_id,p_target_unit_number;
  END IF;

  v_shield:=v_snapshot.shield_start;
  v_hull:=v_snapshot.hull_start;

  FOR v_damage IN
    SELECT *
    FROM public.combat_round_damage crd
    WHERE crd.battle_id=p_battle_id
      AND crd.round_number=p_round_number
      AND crd.target_side=p_target_side
      AND crd.target_unit_type=p_target_unit_type
      AND crd.target_unit_id=p_target_unit_id
      AND crd.target_unit_number=p_target_unit_number
    ORDER BY crd.source_shot_number
    FOR UPDATE
  LOOP
    v_shield_before:=v_shield;
    v_sd:=0;
    v_hd:=0;
    v_exploded:=false;

    -- Once the unit has exploded, later shots may still target it this round,
    -- but they deal no additional damage. This mirrors OGame's target pool:
    -- destroyed units remain targetable until round cleanup.
    IF v_hull > 0 THEN
      SELECT sb.bounced INTO v_bounced
      FROM public.calculate_shield_bounce(v_damage.attack_value,v_snapshot.shield_max) sb;

      IF NOT v_bounced THEN
        v_sd:=least(v_shield,v_damage.attack_value);
        v_shield:=v_shield-v_sd;
        v_hd:=least(v_hull,greatest(v_damage.attack_value-v_sd,0));
        v_hull:=v_hull-v_hd;

        -- OGame rolls the hull-explosion chance after every non-bounced hit,
        -- not once at the end of the round. A shield-only hit can therefore
        -- still trigger the roll when the hull is already below 70%.
        IF v_hull > 0 AND v_hull / v_snapshot.hull_start < 0.70 THEN
          v_exploded:=public.roll_combat_explosion(v_hull,v_snapshot.hull_start);
          IF v_exploded THEN
            v_hull:=0;
            v_shield:=0;
          END IF;
        END IF;
      END IF;
    END IF;

    v_total:=v_sd+v_hd;

    UPDATE public.combat_round_damage
    SET shield_damage=v_sd,
        hull_damage=v_hd
    WHERE id=v_damage.id;

    UPDATE public.combat_shots
    SET target_shield_before=v_shield_before,
        raw_damage=v_damage.attack_value,
        effective_damage=v_total,
        shield_damage=v_sd,
        hull_damage=v_hd,
        target_destroyed=(v_hull<=0)
    WHERE battle_id=p_battle_id
      AND round_number=p_round_number
      AND shot_number=v_damage.source_shot_number;

    v_shots:=v_shots+1;
    v_tsd:=v_tsd+v_sd;
    v_thd:=v_thd+v_hd;
  END LOOP;

  target_side:=p_target_side;
  target_unit_type:=p_target_unit_type;
  target_unit_id:=p_target_unit_id;
  target_unit_number:=p_target_unit_number;
  shots_resolved:=v_shots;
  shield_start:=v_snapshot.shield_start;
  shield_final:=v_shield;
  hull_start:=v_snapshot.hull_start;
  hull_final:=v_hull;
  total_shield_damage:=v_tsd;
  total_hull_damage:=v_thd;
  total_damage:=v_tsd+v_thd;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_combat_round_damage(p_battle_id uuid, p_round_number integer)
RETURNS TABLE(units_updated bigint, units_destroyed bigint)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_unit record;
  v_updated bigint := 0;
  v_destroyed bigint := 0;
BEGIN
  FOR v_unit IN
    SELECT d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number,
           sum(d.shield_damage) AS shield_damage,
           sum(d.hull_damage) AS hull_damage,
           bool_or(s.target_destroyed) AS target_destroyed
    FROM public.combat_round_damage d
    JOIN public.combat_shots s
      ON s.battle_id=d.battle_id
     AND s.round_number=d.round_number
     AND s.shot_number=d.source_shot_number
    WHERE d.battle_id=p_battle_id AND d.round_number=p_round_number
    GROUP BY d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number
  LOOP
    UPDATE public.combat_individual_units cui
    SET shield_current=CASE
          WHEN COALESCE(v_unit.target_destroyed,false) THEN 0
          ELSE greatest(cui.shield_current-v_unit.shield_damage,0)
        END,
        hull_current=CASE
          WHEN COALESCE(v_unit.target_destroyed,false) THEN 0
          ELSE greatest(cui.hull_current-v_unit.hull_damage,0)
        END,
        alive=CASE
          WHEN COALESCE(v_unit.target_destroyed,false) THEN false
          ELSE (greatest(cui.hull_current-v_unit.hull_damage,0)>0)
        END
    WHERE cui.battle_id=p_battle_id AND cui.round_number=p_round_number
      AND cui.side=v_unit.target_side AND cui.unit_type=v_unit.target_unit_type
      AND cui.unit_id=v_unit.target_unit_id AND cui.unit_number=v_unit.target_unit_number;

    IF FOUND THEN
      v_updated:=v_updated+1;
      IF COALESCE(v_unit.target_destroyed,false) THEN
        v_destroyed:=v_destroyed+1;
      END IF;
    END IF;
  END LOOP;

  units_updated:=v_updated;
  units_destroyed:=v_destroyed;
  RETURN NEXT;
END;
$function$;

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
    v_units_destroyed:=COALESCE(v_apply.units_destroyed,0);

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

DROP FUNCTION IF EXISTS public.resolve_combat_round_explosions(uuid, integer);
DROP FUNCTION IF EXISTS public.roll_combat_explosion(numeric, numeric);