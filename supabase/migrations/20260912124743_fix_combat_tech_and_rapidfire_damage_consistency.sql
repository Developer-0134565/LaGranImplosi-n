CREATE OR REPLACE FUNCTION public.calculate_combat_round_pending_damage(p_battle_id uuid, p_round_number integer)
RETURNS TABLE(shots_processed bigint, damage_rows bigint)
LANGUAGE plpgsql
AS $function$
BEGIN
  DELETE FROM public.combat_round_damage
  WHERE battle_id=p_battle_id AND round_number=p_round_number;

  INSERT INTO public.combat_round_damage(
    battle_id,round_number,target_side,target_unit_type,target_unit_id,target_unit_number,
    source_shot_number,attack_value,shield_damage,hull_damage
  )
  SELECT s.battle_id,s.round_number,t.side,t.unit_type,t.unit_id,t.unit_number,
         s.shot_number,s.attack_value,0,0
  FROM public.combat_shots s
  JOIN public.combat_round_snapshot_units t
    ON t.battle_id=s.battle_id
   AND t.round_number=s.round_number
   AND t.side<>s.attacker_side
   AND t.unit_type=s.target_unit_type
   AND t.unit_id=s.target_unit_id
   AND t.unit_number=s.target_unit_number
  WHERE s.battle_id=p_battle_id
    AND s.round_number=p_round_number;

  SELECT count(*)::bigint,count(*)::bigint INTO shots_processed,damage_rows
  FROM public.combat_round_damage
  WHERE battle_id=p_battle_id AND round_number=p_round_number;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_combat_round_damage(p_battle_id uuid,p_round_number integer)
RETURNS TABLE(units_updated bigint,units_destroyed bigint)
LANGUAGE plpgsql
AS $function$
DECLARE v_unit record; v_updated bigint:=0; v_destroyed bigint:=0; v_shield numeric; v_hull numeric; v_sd numeric; v_hd numeric;
BEGIN
  FOR v_unit IN
    SELECT d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number,
           sum(d.shield_damage) shield_damage,sum(d.hull_damage) hull_damage
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
  SELECT count(*) INTO v_destroyed FROM public.combat_individual_units
  WHERE battle_id=p_battle_id AND round_number=p_round_number AND alive=false;
  units_updated:=v_updated; units_destroyed:=v_destroyed; RETURN NEXT;
END;
$function$;