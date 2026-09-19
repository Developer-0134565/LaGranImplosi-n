CREATE OR REPLACE FUNCTION public.resolve_pending_target_damage(p_battle_id uuid,p_round_number integer,p_target_side text,p_target_unit_type text,p_target_unit_id text,p_target_unit_number integer)
RETURNS TABLE(target_side text,target_unit_type text,target_unit_id text,target_unit_number integer,shots_resolved integer,shield_start numeric,shield_final numeric,hull_start numeric,hull_final numeric,total_shield_damage numeric,total_hull_damage numeric,total_damage numeric)
LANGUAGE plpgsql
AS $function$
DECLARE v_snapshot public.combat_round_snapshot_units%ROWTYPE; v_damage public.combat_round_damage%ROWTYPE; v_shield numeric; v_hull numeric; v_sd numeric; v_hd numeric; v_total numeric; v_bounced boolean; v_shots integer:=0; v_tsd numeric:=0; v_thd numeric:=0;
BEGIN
 SELECT * INTO v_snapshot FROM public.combat_round_snapshot_units cru
 WHERE cru.battle_id=p_battle_id AND cru.round_number=p_round_number AND cru.side=p_target_side
   AND cru.unit_type=p_target_unit_type AND cru.unit_id=p_target_unit_id AND cru.unit_number=p_target_unit_number AND cru.alive_start FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Target not found in combat snapshot: % / % / % / %',p_target_side,p_target_unit_type,p_target_unit_id,p_target_unit_number; END IF;
 v_shield:=v_snapshot.shield_start; v_hull:=v_snapshot.hull_start;
 FOR v_damage IN SELECT * FROM public.combat_round_damage crd
 WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number AND crd.target_side=p_target_side
   AND crd.target_unit_type=p_target_unit_type AND crd.target_unit_id=p_target_unit_id AND crd.target_unit_number=p_target_unit_number
 ORDER BY crd.source_shot_number FOR UPDATE
 LOOP
   SELECT sb.bounced INTO v_bounced FROM public.calculate_shield_bounce(v_damage.attack_value,v_snapshot.shield_max) sb;
   v_sd:=0; v_hd:=0;
   IF NOT v_bounced THEN
     v_sd:=least(v_shield,v_damage.attack_value); v_shield:=v_shield-v_sd;
     v_hd:=least(v_hull,greatest(v_damage.attack_value-v_sd,0)); v_hull:=v_hull-v_hd;
   END IF;
   v_total:=v_sd+v_hd;
   UPDATE public.combat_round_damage SET shield_damage=v_sd,hull_damage=v_hd WHERE id=v_damage.id;
   UPDATE public.combat_shots SET target_shield_before=CASE WHEN v_shots=0 THEN v_snapshot.shield_start ELSE target_shield_before END,
       raw_damage=v_damage.attack_value,effective_damage=v_total,shield_damage=v_sd,hull_damage=v_hd,
       target_destroyed=(v_hull<=0)
   WHERE battle_id=p_battle_id AND round_number=p_round_number AND shot_number=v_damage.source_shot_number;
   v_shots:=v_shots+1; v_tsd:=v_tsd+v_sd; v_thd:=v_thd+v_hd;
 END LOOP;
 target_side:=p_target_side; target_unit_type:=p_target_unit_type; target_unit_id:=p_target_unit_id; target_unit_number:=p_target_unit_number;
 shots_resolved:=v_shots; shield_start:=v_snapshot.shield_start; shield_final:=v_shield; hull_start:=v_snapshot.hull_start; hull_final:=v_hull;
 total_shield_damage:=v_tsd; total_hull_damage:=v_thd; total_damage:=v_tsd+v_thd; RETURN NEXT;
END;
$function$;