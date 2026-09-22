-- ============================================================================
-- COMBAT ENGINE PHASE 4A — MIGRATION 1/3
-- DG-11: PARTICIPANT-AWARE UNIT / SNAPSHOT UNIQUENESS
-- DG-10: DOCUMENTED BATTLE HEADER SEMANTICS
-- ----------------------------------------------------------------------------
-- The certified engine keys authoritative unit rows by
--   (battle_id, round_number, side, unit_type, unit_id, unit_number)
-- which cannot distinguish two participating fleets that field the same ship
-- type: both start at unit_number = 1, so the rows collide. For
-- combat_round_snapshot_units the collision was silent, because the snapshot
-- INSERT uses ON CONFLICT … DO NOTHING on that very key.
--
-- This migration makes the identity participant-aware (adds participant_id to
-- both keys) and moves the only ON CONFLICT consumer onto the new key.
--
-- Behaviour with ONE attacking fleet is unchanged: participant_id is constant
-- per side, so the new key is equivalent to the old one for the certified path.
-- No statistic, formula, threshold, round rule, loot, repair or debris logic is
-- touched, and no historical row is modified or deleted.
-- ============================================================================

-- 1) add the participant-aware keys first (the legacy ones stay until the
--    ON CONFLICT consumer has been moved)
alter table public.combat_individual_units
  add constraint combat_individual_units_participant_unique
  unique (battle_id, round_number, participant_id, side, unit_type, unit_id, unit_number);

alter table public.combat_round_snapshot_units
  add constraint combat_round_snapshot_units_participant_unique
  unique (battle_id, round_number, participant_id, side, unit_type, unit_id, unit_number);

-- 2) the snapshot builder is the only ON CONFLICT consumer of the legacy key
create or replace function public.create_combat_round_snapshot(p_battle_id uuid, p_round_number integer)
returns table(units_created bigint, attacker_units bigint, defender_units bigint)
language plpgsql
set search_path to 'public', 'pg_temp'
as $snapshot$
begin
  insert into public.combat_round_snapshot_units(
    battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
    attack,shield_max,shield_start,hull_max,hull_start,alive_start)
  select cui.battle_id,cui.round_number,cui.participant_id,cui.side,cui.unit_type,cui.unit_id,cui.unit_number,
    cui.attack,cui.shield_max,cui.shield_current,cui.hull_max,cui.hull_current,cui.alive
  from public.combat_individual_units cui
  where cui.battle_id=p_battle_id and cui.round_number=p_round_number and cui.alive=true
  on conflict(battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number) do nothing;

  return query select count(*)::bigint,count(*) filter(where side='ATTACKER')::bigint,
    count(*) filter(where side='DEFENDER')::bigint
  from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number;
end;
$snapshot$;

-- 3) drop the two legacy keys (participant-aware keys are now in force)
alter table public.combat_individual_units
  drop constraint combat_individual_units_battle_id_round_number_side_unit_ty_key;

alter table public.combat_round_snapshot_units
  drop constraint combat_round_snapshot_units_unique;

-- 4) DG-10 — document what the battle header means from Phase 4A onwards.
--    The initiating fleet keeps the replay/idempotency key; additional attacking
--    fleets (when a later mission implements them) live in the participant layer.
comment on column public.combat_battles.fleet_id is
  'Phase 4A: the INITIATING (primary) attacking fleet of this battle and the replay/idempotency key for that fleet. Any additional attacking fleet is represented as an ATTACKER/FLEET row in combat_battle_participants and is deliberately not recorded here.';

-- Post-conditions
do $p4a1$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='combat_individual_units_participant_unique' and contype='u'
      and pg_get_constraintdef(oid) like '%participant_id%'
  ) then
    raise exception 'P4A-1: combat_individual_units participant-aware key missing';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='combat_round_snapshot_units_participant_unique' and contype='u'
      and pg_get_constraintdef(oid) like '%participant_id%'
  ) then
    raise exception 'P4A-1: combat_round_snapshot_units participant-aware key missing';
  end if;

  if exists (
    select 1 from pg_constraint
    where conname in ('combat_individual_units_battle_id_round_number_side_unit_ty_key','combat_round_snapshot_units_unique')
  ) then
    raise exception 'P4A-1: a legacy uniqueness key survived';
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace='public'::regnamespace and proname='create_combat_round_snapshot'
      and prosrc like '%on conflict(battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number)%'
  ) then
    raise exception 'P4A-1: snapshot ON CONFLICT still uses the legacy key';
  end if;

  if not exists (
    select 1 from pg_description d join pg_class c on c.oid=d.objoid join pg_attribute a on a.attrelid=c.oid and a.attnum=d.objsubid
    where c.relname='combat_battles' and a.attname='fleet_id' and d.description like '%INITIATING%'
  ) then
    raise exception 'P4A-1: battle header semantics comment missing';
  end if;
end
$p4a1$;
