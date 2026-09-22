-- ============================================================================
-- COMBAT ENGINE PHASE 4B — DEFENDER/FLEET PARTICIPANT REPRESENTATION
-- ----------------------------------------------------------------------------
-- Phase 4A made the participant layer N-fleet on the ATTACKER side and made
-- unit / snapshot / target / loss identity participant-aware. It did NOT touch
-- the defender side: the engine can materialise exactly one DEFENDER participant
-- (participant_type='PLANET').
--
-- This migration makes the DEFENDER/FLEET participant representable by the
-- engine without inventing any gameplay rule:
--
--   1) initialize_individual_combat_units() materialises every DEFENDER/FLEET
--      participant's ships from its own fleet_movement_ships, using ITS OWN
--      owner's technology context (part.player_id) and its own participant_id.
--      This is the exact mirror of the ATTACKER/FLEET branch Phase 4A added.
--      With zero DEFENDER/FLEET participants the statement inserts zero rows, so
--      the certified single-fleet and expedition paths are structurally unchanged.
--
--   2) resolve_attack_arrival() fails closed when a battle owns DEFENDER/FLEET
--      participants. Multi-defender settlement (which surviving ship belongs to
--      which defending fleet, and when that fleet returns) is a PRODUCT DECISION
--      that does not exist yet. Refusing to settle is the only safe behaviour:
--      silently ignoring those participants would destroy their ships in combat
--      while returning the fleet with its original composition.
--
-- Explicitly NOT in this migration (all product decisions, see §20):
--   * DEFEND dispatch (start_support_fleet keeps refusing DEFEND);
--   * ACS grouping / invitation / join window / fleet-count cap;
--   * per-fleet survivor, loot and debris attribution semantics;
--   * multi-defender settlement and defending-fleet return timing;
--   * battle-report per-fleet projection;
--   * any formula, percentage, threshold, RNG semantic or round rule.
--
-- No producer of DEFENDER/FLEET participants exists: the only functions that
-- insert into combat_battle_participants are resolve_combat,
-- resolve_expedition_pirates and resolve_expedition_aliens, and none creates a
-- DEFENDER/FLEET row. (2) is therefore inert today and fail-closed from the
-- moment a producer is added.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) DEFENDER/FLEET unit materialisation
--    Only the new statement is added; every pre-existing statement is preserved
--    verbatim. The FOUND check after the ATTACKER insert is intentionally NOT
--    repeated for defenders: "no defending fleet" is the certified case.
-- ---------------------------------------------------------------------------
create or replace function public.initialize_individual_combat_units(p_battle_id uuid)
returns integer
language plpgsql
set search_path to 'public', 'pg_temp'
as $init_units$
declare
    v_planet_id uuid; v_defender_player_id uuid; v_defender_participant_id uuid; v_count integer;
begin
    if not exists (select 1 from public.combat_battles cb where cb.id=p_battle_id) then
      raise exception 'Batalla % no encontrada',p_battle_id;
    end if;
    select cb.defender_planet_id into v_planet_id from public.combat_battles cb where cb.id=p_battle_id;
    select p.player_id into v_defender_player_id from public.planets p where p.id=v_planet_id;
    select id into v_defender_participant_id from public.combat_battle_participants
    where battle_id=p_battle_id and side='DEFENDER' and participant_type='PLANET' and planet_id=v_planet_id;
    if v_defender_participant_id is null then
      raise exception 'Battle % missing combat participants',p_battle_id;
    end if;

    insert into public.combat_individual_units(
      battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    select p_battle_id,1,part.id,'ATTACKER','SHIP',fms.ship_id,gs.n,
      public.get_combat_ship_attack(part.player_id,fms.ship_id),
      public.get_combat_ship_shield(part.player_id,fms.ship_id),
      public.get_combat_ship_shield(part.player_id,fms.ship_id),
      public.get_combat_ship_hull(part.player_id,fms.ship_id)*10,
      public.get_combat_ship_hull(part.player_id,fms.ship_id),
      public.get_combat_ship_hull(part.player_id,fms.ship_id)
    from public.combat_battle_participants part
    join public.fleet_movement_ships fms on fms.fleet_id = part.fleet_id
    cross join lateral generate_series(1,fms.quantity) gs(n)
    where part.battle_id=p_battle_id and part.side='ATTACKER' and part.participant_type='FLEET';
    if not found then
      raise exception 'Battle % missing combat participants',p_battle_id;
    end if;

    insert into public.combat_individual_units(
      battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    select p_battle_id,1,v_defender_participant_id,'DEFENDER','SHIP',ps.ship_id,gs.n,
      public.get_combat_ship_attack(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_shield(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_shield(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id)*10,
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id),
      public.get_combat_ship_hull(v_defender_player_id,ps.ship_id)
    from public.planet_ships ps cross join lateral generate_series(1,ps.quantity) gs(n)
    where ps.planet_id=v_planet_id and ps.quantity>0;

    insert into public.combat_individual_units(
      battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    select p_battle_id,1,v_defender_participant_id,'DEFENDER','DEFENSE',pd.defense_id,gs.n,
      public.get_combat_defense_attack(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_shield(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_shield(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id)*10,
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id),
      public.get_combat_defense_hull(v_defender_player_id,pd.defense_id)
    from public.planet_defenses pd cross join lateral generate_series(1,pd.quantity) gs(n)
    where pd.planet_id=v_planet_id and pd.quantity>0;

    -- PHASE 4B: DEFENDER/FLEET participants.
    -- A defending fleet's ships are SHIP units (never DEFENSE), they belong to
    -- that participant and they are statted with that fleet's OWN owner context.
    -- The participant-aware unique key (battle, round, participant, side,
    -- unit_type, unit_id, unit_number) keeps "defender fleet A cruiser #1",
    -- "defender fleet B cruiser #1" and "planet cruiser #1" as three distinct
    -- units. Identical to the certified ATTACKER/FLEET branch above.
    insert into public.combat_individual_units(
      battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    select p_battle_id,1,part.id,'DEFENDER','SHIP',fms.ship_id,gs.n,
      public.get_combat_ship_attack(part.player_id,fms.ship_id),
      public.get_combat_ship_shield(part.player_id,fms.ship_id),
      public.get_combat_ship_shield(part.player_id,fms.ship_id),
      public.get_combat_ship_hull(part.player_id,fms.ship_id)*10,
      public.get_combat_ship_hull(part.player_id,fms.ship_id),
      public.get_combat_ship_hull(part.player_id,fms.ship_id)
    from public.combat_battle_participants part
    join public.fleet_movement_ships fms on fms.fleet_id = part.fleet_id
    cross join lateral generate_series(1,fms.quantity) gs(n)
    where part.battle_id=p_battle_id and part.side='DEFENDER' and part.participant_type='FLEET';

    select count(*)::integer into v_count from public.combat_individual_units
    where battle_id=p_battle_id and round_number=1;
    return v_count;
end;
$init_units$;

revoke all on function public.initialize_individual_combat_units(uuid) from public, anon, authenticated;
grant execute on function public.initialize_individual_combat_units(uuid) to service_role;


-- ---------------------------------------------------------------------------
-- 2) Fail-closed settlement contract
--    Only the guard is added; every pre-existing statement is preserved verbatim.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_attack_arrival(p_fleet_id uuid)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public'
as $resolve_attack_arrival$
declare
  v_fleet public.fleet_movements%rowtype; v_battle_id uuid; v_last_round integer;
  v_attacker_participant_id uuid; v_defender_participant_id uuid;
begin
  select * into v_fleet from public.fleet_movements where id=p_fleet_id for update;
  if not found then raise exception 'Fleet % no existe',p_fleet_id; end if;
  if v_fleet.mission_type<>'ATTACK' then raise exception 'Fleet % no es ATTACK',p_fleet_id; end if;
  if v_fleet.status not in ('ARRIVED','RETURNING','COMPLETED') then raise exception 'Fleet % no está lista para resolver ataque. Estado: %',p_fleet_id,v_fleet.status; end if;
  if v_fleet.status<>'ARRIVED' then
    select cb.id into v_battle_id from public.combat_battles cb where cb.fleet_id=p_fleet_id order by cb.created_at limit 1;
    if v_battle_id is null then raise exception 'Attack fleet % has no combat battle',p_fleet_id; end if;
    return v_battle_id;
  end if;

  perform public.update_planet_resources_until(v_fleet.destination_planet_id,v_fleet.arrives_at);
  perform public.process_shipyard_queue_until(v_fleet.destination_planet_id,v_fleet.arrives_at);
  perform public.process_defense_queue_until(v_fleet.destination_planet_id,v_fleet.arrives_at);
  v_battle_id:=public.resolve_combat(p_fleet_id);

  select id into v_attacker_participant_id from public.combat_battle_participants
  where battle_id=v_battle_id and side='ATTACKER' and participant_type='FLEET' and fleet_id=p_fleet_id;
  select id into v_defender_participant_id from public.combat_battle_participants
  where battle_id=v_battle_id and side='DEFENDER' and participant_type='PLANET' and planet_id=v_fleet.destination_planet_id;
  if v_attacker_participant_id is null or v_defender_participant_id is null then raise exception 'Battle % missing settlement participants',v_battle_id; end if;

  -- PHASE 4B fail-closed guard. This settlement path can attribute survivors for
  -- exactly one attacking fleet and the stationary planet. A DEFENDER/FLEET
  -- participant has no defined survivor/return semantics yet, so settling the
  -- battle would silently destroy its ships and return the fleet intact.
  if exists (select 1 from public.combat_battle_participants part
             where part.battle_id=v_battle_id and part.side='DEFENDER' and part.participant_type='FLEET') then
    raise exception 'MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED: battle % owns defending fleet participants; single-fleet settlement cannot attribute their survivors',v_battle_id;
  end if;

  if not exists(select 1 from public.combat_battles where id=v_battle_id and finished_at is not null) then perform public.run_expedition_combat(v_battle_id); end if;
  select max(round_number) into v_last_round from public.combat_individual_units where battle_id=v_battle_id;
  if v_last_round is null then raise exception 'Battle % finished without rounds',v_battle_id; end if;
  perform public.sync_combat_battle_final_counts(v_battle_id);

  delete from public.fleet_movement_ships where fleet_id=p_fleet_id;
  insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
  select p_fleet_id,ciu.unit_id,count(*)::bigint from public.combat_individual_units ciu
  where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.participant_id=v_attacker_participant_id
    and ciu.side='ATTACKER' and ciu.unit_type='SHIP' and ciu.alive group by ciu.unit_id;

  update public.planet_ships ps set quantity=coalesce(src.quantity,0)
  from (select ciu.unit_id,count(*)::bigint quantity from public.combat_individual_units ciu
    where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.participant_id=v_defender_participant_id
      and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.alive group by ciu.unit_id) src
  where ps.planet_id=v_fleet.destination_planet_id and ps.ship_id=src.unit_id;

  update public.planet_ships ps set quantity=0
  where ps.planet_id=v_fleet.destination_planet_id
    and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
      and ciu.participant_id=v_defender_participant_id and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.unit_id=ps.ship_id)
    and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
      and ciu.participant_id=v_defender_participant_id and ciu.side='DEFENDER' and ciu.unit_type='SHIP'
      and ciu.unit_id=ps.ship_id and ciu.alive);

  update public.planet_defenses pd set quantity=coalesce(src.quantity,0)
  from (select ciu.unit_id,count(*)::bigint quantity from public.combat_individual_units ciu
    where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.participant_id=v_defender_participant_id
      and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.alive group by ciu.unit_id) src
  where pd.planet_id=v_fleet.destination_planet_id and pd.defense_id=src.unit_id;

  update public.planet_defenses pd set quantity=0
  where pd.planet_id=v_fleet.destination_planet_id
    and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
      and ciu.participant_id=v_defender_participant_id and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id)
    and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
      and ciu.participant_id=v_defender_participant_id and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE'
      and ciu.unit_id=pd.defense_id and ciu.alive);

  perform * from public.apply_attack_loot(v_battle_id);
  perform * from public.repair_defenses_after_combat(v_battle_id);
  perform public.create_combat_debris(v_battle_id);
  update public.fleet_movements set status='RETURNING',returns_at=arrives_at+(arrives_at-started_at)
  where id=p_fleet_id and status='ARRIVED';
  return v_battle_id;
end;
$resolve_attack_arrival$;

revoke all on function public.resolve_attack_arrival(uuid) from public, anon, authenticated;
grant execute on function public.resolve_attack_arrival(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Post-conditions
-- ---------------------------------------------------------------------------
do $p4b$
begin
  if not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='initialize_individual_combat_units'
                   and prosrc like '%part.side=''DEFENDER'' and part.participant_type=''FLEET''%') then
    raise exception 'P4B: defender-fleet unit initialisation is missing';
  end if;

  if not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='initialize_individual_combat_units'
                   and prosrc like '%part.side=''ATTACKER'' and part.participant_type=''FLEET''%') then
    raise exception 'P4B: the Phase 4A attacker-participant initialisation was lost';
  end if;

  if not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='resolve_attack_arrival'
                   and prosrc like '%MULTI_DEFENDER_SETTLEMENT_NOT_DEFINED%') then
    raise exception 'P4B: the fail-closed settlement guard is missing';
  end if;

  if has_function_privilege('anon','public.initialize_individual_combat_units(uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.initialize_individual_combat_units(uuid)','EXECUTE')
     or has_function_privilege('anon','public.resolve_attack_arrival(uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.resolve_attack_arrival(uuid)','EXECUTE') then
    raise exception 'P4B: internal combat EXECUTE permissions were widened';
  end if;

  if not has_function_privilege('service_role','public.initialize_individual_combat_units(uuid)','EXECUTE')
     or not has_function_privilege('service_role','public.resolve_attack_arrival(uuid)','EXECUTE') then
    raise exception 'P4B: the engine lost EXECUTE on a required internal function';
  end if;
end
$p4b$;
