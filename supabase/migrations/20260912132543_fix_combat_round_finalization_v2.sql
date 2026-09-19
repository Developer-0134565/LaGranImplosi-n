CREATE OR REPLACE FUNCTION public.apply_combat_round_damage(p_battle_id uuid, p_round_number integer)
RETURNS TABLE(units_updated bigint, units_destroyed bigint)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_unit record;
  v_updated bigint := 0;
  v_destroyed bigint := 0;
BEGIN
  FOR v_unit IN
    SELECT d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number,
           sum(d.shield_damage) AS shield_damage,
           sum(d.hull_damage) AS hull_damage
    FROM public.combat_round_damage d
    WHERE d.battle_id=p_battle_id AND d.round_number=p_round_number
    GROUP BY d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number
  LOOP
    UPDATE public.combat_individual_units cui
    SET shield_current=greatest(cui.shield_current-v_unit.shield_damage,0),
        hull_current=greatest(cui.hull_current-v_unit.hull_damage,0),
        alive=(greatest(cui.hull_current-v_unit.hull_damage,0)>0)
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

CREATE OR REPLACE FUNCTION public.create_combat_next_round(p_battle_id uuid, p_previous_round integer)
RETURNS TABLE(next_round integer, units_created bigint, attacker_units bigint, defender_units bigint)
LANGUAGE plpgsql
AS $function$
DECLARE v_next_round integer := p_previous_round + 1;
BEGIN
  IF p_previous_round >= 6 THEN
    RAISE EXCEPTION 'No se puede crear una ronda posterior a la 6';
  END IF;

  IF EXISTS (SELECT 1 FROM public.combat_individual_units WHERE battle_id=p_battle_id AND round_number=v_next_round) THEN
    RETURN QUERY
    SELECT v_next_round,COUNT(*)::bigint,
           COUNT(*) FILTER (WHERE side='ATTACKER')::bigint,
           COUNT(*) FILTER (WHERE side='DEFENDER')::bigint
    FROM public.combat_individual_units
    WHERE battle_id=p_battle_id AND round_number=v_next_round;
    RETURN;
  END IF;

  INSERT INTO public.combat_individual_units(
    battle_id,round_number,side,unit_type,unit_id,unit_number,
    attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)
  SELECT cui.battle_id,v_next_round,cui.side,cui.unit_type,cui.unit_id,cui.unit_number,
         cui.attack,cui.shield_max,cui.shield_max,cui.structural_integrity,
         cui.hull_max,cui.hull_current,true
  FROM public.combat_individual_units cui
  WHERE cui.battle_id=p_battle_id AND cui.round_number=p_previous_round AND cui.alive=true;

  RETURN QUERY
  SELECT v_next_round,COUNT(*)::bigint,
         COUNT(*) FILTER (WHERE side='ATTACKER')::bigint,
         COUNT(*) FILTER (WHERE side='DEFENDER')::bigint
  FROM public.combat_individual_units
  WHERE battle_id=p_battle_id AND round_number=v_next_round;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_combat_round_explosions(p_battle_id uuid,p_round_number integer)
RETURNS TABLE(side text,unit_type text,unit_id text,unit_number integer,hull_before numeric,hull_percent numeric,explosion_probability numeric,exploded boolean)
LANGUAGE plpgsql
AS $function$
DECLARE v_unit public.combat_individual_units%ROWTYPE; v_hull_percent numeric; v_probability numeric; v_exploded boolean;
BEGIN
  FOR v_unit IN
    SELECT cui.* FROM public.combat_individual_units cui
    WHERE cui.battle_id=p_battle_id AND cui.round_number=p_round_number
      AND cui.alive=true AND cui.hull_current>0 AND cui.hull_max>0
      AND cui.hull_current/cui.hull_max<0.70
    ORDER BY cui.side,cui.unit_type,cui.unit_id,cui.unit_number
    FOR UPDATE
  LOOP
    v_hull_percent:=v_unit.hull_current/v_unit.hull_max;
    v_probability:=1-v_hull_percent;
    v_exploded:=public.roll_combat_explosion(v_unit.hull_current,v_unit.hull_max);
    IF v_exploded THEN
      UPDATE public.combat_individual_units SET alive=false WHERE id=v_unit.id;
    END IF;
    side:=v_unit.side; unit_type:=v_unit.unit_type; unit_id:=v_unit.unit_id; unit_number:=v_unit.unit_number;
    hull_before:=v_unit.hull_current; hull_percent:=round(v_hull_percent*100,2);
    explosion_probability:=round(v_probability*100,2); exploded:=v_exploded;
    RETURN NEXT;
  END LOOP;
END;
$function$;