ALTER TABLE public.combat_round_damage ADD COLUMN IF NOT EXISTS exploded boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.resolve_pending_target_damage(
  p_battle_id uuid,
  p_round_number integer,
  p_target_side text,
  p_target_unit_type text,
  p_target_unit_id text,
  p_target_unit_number integer
)
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
  SELECT * INTO v_snapshot FROM public.combat_round_snapshot_units cru
  WHERE cru.battle_id=p_battle_id AND cru.round_number=p_round_number AND cru.side=p_target_side
    AND cru.unit_type=p_target_unit_type AND cru.unit_id=p_target_unit_id AND cru.unit_number=p_target_unit_number
    AND cru.alive_start FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Target not found in combat snapshot: % / % / % / %',p_target_side,p_target_unit_type,p_target_unit_id,p_target_unit_number; END IF;

  v_shield:=v_snapshot.shield_start;
  v_hull:=v_snapshot.hull_start;

  FOR v_damage IN
    SELECT * FROM public.combat_round_damage crd
    WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number
      AND crd.target_side=p_target_side AND crd.target_unit_type=p_target_unit_type
      AND crd.target_unit_id=p_target_unit_id AND crd.target_unit_number=p_target_unit_number
    ORDER BY crd.source_shot_number FOR UPDATE
  LOOP
    v_shield_before:=v_shield;
    v_sd:=0; v_hd:=0; v_exploded:=false;

    IF v_hull > 0 THEN
      SELECT sb.bounced INTO v_bounced
      FROM public.calculate_shield_bounce(v_damage.attack_value,v_snapshot.shield_max) sb;

      IF NOT v_bounced THEN
        v_sd:=least(v_shield,v_damage.attack_value);
        v_shield:=v_shield-v_sd;
        v_hd:=least(v_hull,greatest(v_damage.attack_value-v_sd,0));
        v_hull:=v_hull-v_hd;

        IF v_hull > 0 AND v_hull / v_snapshot.hull_start < 0.70 THEN
          v_exploded := random() < (1 - v_hull / v_snapshot.hull_start);
          IF v_exploded THEN
            v_hull:=0;
            v_shield:=0;
          END IF;
        END IF;
      END IF;
    END IF;

    v_total:=v_sd+v_hd;
    UPDATE public.combat_round_damage
    SET shield_damage=v_sd,hull_damage=v_hd,exploded=v_exploded
    WHERE id=v_damage.id;

    UPDATE public.combat_shots
    SET target_shield_before=v_shield_before,raw_damage=v_damage.attack_value,effective_damage=v_total,
        shield_damage=v_sd,hull_damage=v_hd,target_destroyed=(v_hull<=0)
    WHERE battle_id=p_battle_id AND round_number=p_round_number AND shot_number=v_damage.source_shot_number;

    v_shots:=v_shots+1; v_tsd:=v_tsd+v_sd; v_thd:=v_thd+v_hd;
  END LOOP;

  target_side:=p_target_side; target_unit_type:=p_target_unit_type; target_unit_id:=p_target_unit_id;
  target_unit_number:=p_target_unit_number; shots_resolved:=v_shots; shield_start:=v_snapshot.shield_start;
  shield_final:=v_shield; hull_start:=v_snapshot.hull_start; hull_final:=v_hull;
  total_shield_damage:=v_tsd; total_hull_damage:=v_thd; total_damage:=v_tsd+v_thd;
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
           bool_or(d.exploded) AS exploded
    FROM public.combat_round_damage d
    WHERE d.battle_id=p_battle_id AND d.round_number=p_round_number
    GROUP BY d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number
  LOOP
    UPDATE public.combat_individual_units cui
    SET shield_current=CASE WHEN v_unit.exploded THEN 0 ELSE greatest(cui.shield_current-v_unit.shield_damage,0) END,
        hull_current=CASE WHEN v_unit.exploded THEN 0 ELSE greatest(cui.hull_current-v_unit.hull_damage,0) END,
        alive=CASE WHEN v_unit.exploded THEN false ELSE greatest(cui.hull_current-v_unit.hull_damage,0)>0 END
    WHERE cui.battle_id=p_battle_id AND cui.round_number=p_round_number
      AND cui.side=v_unit.target_side AND cui.unit_type=v_unit.target_unit_type
      AND cui.unit_id=v_unit.target_unit_id AND cui.unit_number=v_unit.target_unit_number;
    IF FOUND THEN v_updated:=v_updated+1; END IF;
  END LOOP;

  SELECT count(*) INTO v_destroyed
  FROM public.combat_individual_units
  WHERE battle_id=p_battle_id AND round_number=p_round_number AND alive=false;

  units_updated:=v_updated;
  units_destroyed:=v_destroyed;
  RETURN NEXT;
END;
$function$;