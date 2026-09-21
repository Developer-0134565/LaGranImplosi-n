-- ============================================================================
-- COMBAT ENGINE PHASE 2 — CB-03: DEBRIS PROVENANCE / ORDER HARDENING
-- ----------------------------------------------------------------------------
-- Phase 0 found that `create_combat_debris` checked its provenance row and then
-- credited the debris field, writing the `combat_debris_generations` row only
-- afterwards with `ON CONFLICT (battle_id) DO NOTHING`. Two concurrent
-- invocations of the same battle could therefore both pass the check, both credit
-- `debris_fields`, and let only one provenance row survive — a double credit with
-- a single generation record.
--
-- Reachability (recorded in README_COMBAT_ENGINE section 16):
--   * the function is `service_role`-only, so no client can reach it;
--   * its only engine caller is `resolve_attack_arrival`, which runs under the
--     global advisory lock of `process_fleet_movements`, holds the fleet row lock
--     and is protected by `UNIQUE (fleet_id)` on `combat_battles`, so the same
--     battle cannot be resolved twice concurrently;
--   * the residual exposure is an out-of-band concurrent `service_role` call.
--
-- Hardening (minimal, transactional, no formula or percentage change):
--   1. the whole function now takes a battle-scoped `pg_advisory_xact_lock`, so
--      two invocations for the same battle serialize: the second one observes the
--      committed provenance row and returns `already_generated = true` without
--      crediting anything. The guard survives replay, worker retry and the
--      per-fleet retry boundary introduced by CB-04.
--   2. the defensive `ON CONFLICT` branch (now unreachable while the lock is held)
--      raises a WARNING instead of silently continuing, so any future re-entry
--      through a different path is observable in the logs.
--
-- Debris percentages, formulas, balances and historical debris are untouched.
-- ============================================================================

do $cb03$
declare
  v_def text;
  v_occ integer;
  v_lock_anchor text := 'begin' || chr(10) ||
                        '    select cdg.debris_field_id into v_existing_debris_id';
  v_conflict_anchor text := '    if not found then' || chr(10) ||
                            '        select cdg.debris_field_id into v_debris_id from public.combat_debris_generations cdg where cdg.battle_id=p_battle_id;';
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace='public'::regnamespace and p.proname='create_combat_debris';

  if v_def is null then
    raise exception 'CB-03: create_combat_debris not found';
  end if;

  -- 1. battle-scoped serialization
  v_occ := (length(v_def) - length(replace(v_def, v_lock_anchor, ''))) / length(v_lock_anchor);
  if v_occ <> 1 then
    raise exception 'CB-03: lock anchor matched % time(s), expected 1', v_occ;
  end if;

  v_def := replace(v_def, v_lock_anchor,
    'begin' || chr(10) ||
    '    perform pg_advisory_xact_lock(hashtextextended(''combat_debris:''||p_battle_id::text, 0));' || chr(10) ||
    '    select cdg.debris_field_id into v_existing_debris_id');

  -- 2. make the defensive branch observable
  v_occ := (length(v_def) - length(replace(v_def, v_conflict_anchor, ''))) / length(v_conflict_anchor);
  if v_occ <> 1 then
    raise exception 'CB-03: conflict anchor matched % time(s), expected 1', v_occ;
  end if;

  v_def := replace(v_def, v_conflict_anchor,
    '    if not found then' || chr(10) ||
    '        raise warning ''COMBAT_DEBRIS_CONFLICT battle % lost the provenance race (field credited, generation row already present)'', p_battle_id;' || chr(10) ||
    '        select cdg.debris_field_id into v_debris_id from public.combat_debris_generations cdg where cdg.battle_id=p_battle_id;');

  execute v_def;

  -- Post-conditions
  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='create_combat_debris'
      and p.prosrc like '%pg_advisory_xact_lock(hashtextextended(''combat_debris:''%'
  ) then
    raise exception 'CB-03: the battle-scoped advisory lock is missing after the repair';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace and p.proname='create_combat_debris'
      and p.prosrc like '%COMBAT_DEBRIS_CONFLICT%'
  ) then
    raise exception 'CB-03: the defensive branch is not observable after the repair';
  end if;

  if has_function_privilege('anon', 'public.create_combat_debris(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.create_combat_debris(uuid)', 'EXECUTE') then
    raise exception 'CB-03: create_combat_debris must stay internal';
  end if;
end
$cb03$;
