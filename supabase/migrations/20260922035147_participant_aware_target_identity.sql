-- ============================================================================
-- COMBAT ENGINE PHASE 4A — MIGRATION 2/3
-- DG-12: PARTICIPANT-AWARE TARGET IDENTITY
-- ----------------------------------------------------------------------------
-- The per-target damage resolver located a target by
--   (battle, round, side, unit_type, unit_id, unit_number)
-- and the round orchestrator iterated that same identity over the damage ledger.
-- Two participating fleets fielding the same ship type produce identical tuples,
-- so both units resolved as the SAME target.
--
-- This migration adds participant_id to that identity:
--   · resolve_pending_target_damage gains p_target_participant_id and returns it;
--   · its snapshot lookup and its damage-ledger cursor are keyed by it;
--   · process_combat_round_v2 iterates DISTINCT target_participant_id too.
--
-- Nothing else changes: shield absorption, hull damage, the 1 % bounce rule, the
-- 70 % explosion roll, rapidfire, round limits and all statistics stay identical.
-- With one attacking fleet participant_id is constant, so the certified path is
-- unchanged.
-- ============================================================================

create or replace function public.resolve_pending_target_damage(
    p_battle_id uuid,
    p_round_number integer,
    p_target_participant_id uuid,
    p_target_side text,
    p_target_unit_type text,
    p_target_unit_id text,
    p_target_unit_number integer)
returns table(target_participant_id uuid, target_side text, target_unit_type text, target_unit_id text,
              target_unit_number integer, shots_resolved integer, shield_start numeric, shield_final numeric,
              hull_start numeric, hull_final numeric, total_shield_damage numeric, total_hull_damage numeric,
              total_damage numeric)
language plpgsql
set search_path to 'public', 'pg_temp'
as $rptd$
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
  WHERE cru.battle_id=p_battle_id AND cru.round_number=p_round_number
    AND cru.participant_id=p_target_participant_id AND cru.side=p_target_side
    AND cru.unit_type=p_target_unit_type AND cru.unit_id=p_target_unit_id AND cru.unit_number=p_target_unit_number
    AND cru.alive_start FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target not found in combat snapshot: participant % / % / % / % / %',
      p_target_participant_id,p_target_side,p_target_unit_type,p_target_unit_id,p_target_unit_number;
  END IF;

  v_shield:=v_snapshot.shield_start;
  v_hull:=v_snapshot.hull_start;

  FOR v_damage IN
    SELECT * FROM public.combat_round_damage crd
    WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number
      AND crd.target_participant_id=p_target_participant_id
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

  target_participant_id:=p_target_participant_id;
  target_side:=p_target_side; target_unit_type:=p_target_unit_type; target_unit_id:=p_target_unit_id;
  target_unit_number:=p_target_unit_number; shots_resolved:=v_shots; shield_start:=v_snapshot.shield_start;
  shield_final:=v_shield; hull_start:=v_snapshot.hull_start; hull_final:=v_hull;
  total_shield_damage:=v_tsd; total_hull_damage:=v_thd; total_damage:=v_tsd+v_thd;
  RETURN NEXT;
END;
$rptd$;

-- 2) point the round orchestrator at the participant-aware identity
do $p4a2$
declare
  v_def text;
  v_old text;
  v_new text;
  v_occ integer;
  v_eol text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace='public'::regnamespace and p.proname='process_combat_round_v2';

  if v_def is null then
    raise exception 'P4A-2: process_combat_round_v2 not found';
  end if;

  v_eol := case when v_def like '%' || chr(13) || chr(10) || '%' then chr(13) || chr(10) else chr(10) end;

  v_old := replace($old$    FOR v_target IN
        SELECT DISTINCT crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
        FROM public.combat_round_damage crd
        WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number
        ORDER BY crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
    LOOP
        PERFORM * FROM public.resolve_pending_target_damage(
            p_battle_id,p_round_number,v_target.target_side,v_target.target_unit_type,
            v_target.target_unit_id,v_target.target_unit_number
        );
    END LOOP;$old$, chr(10), v_eol);

  v_new := replace($new$    FOR v_target IN
        SELECT DISTINCT crd.target_participant_id,crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
        FROM public.combat_round_damage crd
        WHERE crd.battle_id=p_battle_id AND crd.round_number=p_round_number
        ORDER BY crd.target_participant_id,crd.target_side,crd.target_unit_type,crd.target_unit_id,crd.target_unit_number
    LOOP
        PERFORM * FROM public.resolve_pending_target_damage(
            p_battle_id,p_round_number,v_target.target_participant_id,v_target.target_side,v_target.target_unit_type,
            v_target.target_unit_id,v_target.target_unit_number
        );
    END LOOP;$new$, chr(10), v_eol);

  v_occ := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_occ <> 1 then
    raise exception 'P4A-2: target loop fragment matched % time(s), expected 1', v_occ;
  end if;

  execute replace(v_def, v_old, v_new);
end
$p4a2$;

-- 3) retire the ambiguous signature (its only caller now uses the new one)
drop function if exists public.resolve_pending_target_damage(uuid, integer, text, text, text, integer);

-- Post-conditions
do $p4a2c$
begin
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_pending_target_damage'
      and pg_get_function_identity_arguments(p.oid) like '%p_target_participant_id%'
      and p.prosrc like '%cru.participant_id=p_target_participant_id%'
      and p.prosrc like '%crd.target_participant_id=p_target_participant_id%'
  ) then
    raise exception 'P4A-2: participant-aware resolver missing or incomplete';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='resolve_pending_target_damage'
      and pg_get_function_identity_arguments(p.oid) not like '%p_target_participant_id%'
  ) then
    raise exception 'P4A-2: the ambiguous resolver signature survived';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='process_combat_round_v2'
      and p.prosrc like '%v_target.target_participant_id%'
      and p.prosrc like '%SELECT DISTINCT crd.target_participant_id%'
  ) then
    raise exception 'P4A-2: round orchestrator still iterates participant-less targets';
  end if;
end
$p4a2c$;
