-- ============================================================================
-- COMBAT ENGINE PHASE 4A — MIGRATION 3/3
-- DG-13 participant-aware loss identity · §9 participant-aware unit init
-- plus: re-apply the Phase 1/2 EXECUTE hardening lost by signature changes
-- ----------------------------------------------------------------------------
-- 1) the loss readers grouped losses by (side, unit_id) only, so two fleets
--    fielding the same ship type produced ONE merged row: the engine could not say
--    which fleet lost the units. participant_id is added to the grouping, to the
--    returned columns, to the join and to the ordering. Totals are unchanged
--    (callers aggregate) and with one fleet the values are identical.
-- 2) initialize_individual_combat_units derived the attacker participant from the
--    single combat_battles.fleet_id; it now iterates every ATTACKER/FLEET
--    participant of the battle.
-- 3) DROP + CREATE (return-type change) and a new resolver signature reset EXECUTE
--    privileges to PUBLIC, so the hardening is re-applied to all three.
-- No formula, threshold, RNG semantic, percentage or gameplay rule is touched.
-- ============================================================================

drop function public.calculate_combat_ship_losses(uuid);

create function public.calculate_combat_ship_losses(p_battle_id uuid)
returns table(participant_id uuid, side text, unit_id text, initial_quantity bigint, surviving_quantity bigint,
              destroyed_quantity bigint, metal_lost numeric, crystal_lost numeric, deuterium_lost numeric)
language sql
set search_path to 'public', 'pg_temp'
as $ship_losses$
WITH initial_units AS (
    SELECT cui.participant_id, cui.side, cui.unit_id, COUNT(*)::bigint AS initial_quantity
    FROM public.combat_individual_units AS cui
    WHERE cui.battle_id = p_battle_id AND cui.round_number = 1 AND cui.unit_type = 'SHIP'
    GROUP BY cui.participant_id, cui.side, cui.unit_id
),
final_units AS (
    SELECT cui.participant_id, cui.side, cui.unit_id,
           COUNT(*) FILTER (WHERE cui.alive = true)::bigint AS surviving_quantity
    FROM public.combat_individual_units AS cui
    WHERE cui.battle_id = p_battle_id
      AND cui.round_number = (SELECT MAX(x.round_number) FROM public.combat_individual_units AS x
                              WHERE x.battle_id = p_battle_id)
      AND cui.unit_type = 'SHIP'
    GROUP BY cui.participant_id, cui.side, cui.unit_id
)
SELECT
    i.participant_id,
    i.side,
    i.unit_id,
    i.initial_quantity,
    COALESCE(f.surviving_quantity, 0)::bigint AS surviving_quantity,
    (i.initial_quantity - COALESCE(f.surviving_quantity, 0))::bigint AS destroyed_quantity,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(s.base_metal, 0))::numeric AS metal_lost,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(s.base_crystal, 0))::numeric AS crystal_lost,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(s.base_deuterium, 0))::numeric AS deuterium_lost
FROM initial_units AS i
LEFT JOIN final_units AS f
    ON f.participant_id = i.participant_id AND f.side = i.side AND f.unit_id = i.unit_id
LEFT JOIN public.ship_definitions AS s ON s.id = i.unit_id
ORDER BY i.participant_id, i.side, i.unit_id;
$ship_losses$;

revoke all on function public.calculate_combat_ship_losses(uuid) from public, anon, authenticated;

drop function public.calculate_combat_defense_losses(uuid);

create function public.calculate_combat_defense_losses(p_battle_id uuid)
returns table(participant_id uuid, side text, unit_id text, initial_quantity bigint, surviving_quantity bigint,
              destroyed_quantity bigint, metal_lost numeric, crystal_lost numeric, deuterium_lost numeric)
language sql
set search_path to 'public', 'pg_temp'
as $defense_losses$
WITH initial_units AS (
    SELECT cui.participant_id, cui.side, cui.unit_id, COUNT(*)::bigint AS initial_quantity
    FROM public.combat_individual_units AS cui
    WHERE cui.battle_id = p_battle_id AND cui.round_number = 1 AND cui.unit_type = 'DEFENSE'
    GROUP BY cui.participant_id, cui.side, cui.unit_id
),
final_round AS (
    SELECT MAX(cui.round_number) AS round_number
    FROM public.combat_individual_units AS cui
    WHERE cui.battle_id = p_battle_id
),
final_units AS (
    SELECT cui.participant_id, cui.side, cui.unit_id,
           COUNT(*) FILTER (WHERE cui.alive = true)::bigint AS surviving_quantity
    FROM public.combat_individual_units AS cui
    CROSS JOIN final_round AS fr
    WHERE cui.battle_id = p_battle_id AND cui.round_number = fr.round_number AND cui.unit_type = 'DEFENSE'
    GROUP BY cui.participant_id, cui.side, cui.unit_id
)
SELECT
    i.participant_id, i.side, i.unit_id, i.initial_quantity,
    COALESCE(f.surviving_quantity, 0)::bigint AS surviving_quantity,
    (i.initial_quantity - COALESCE(f.surviving_quantity, 0))::bigint AS destroyed_quantity,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(d.metal_cost, 0))::numeric AS metal_lost,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(d.crystal_cost, 0))::numeric AS crystal_lost,
    ((i.initial_quantity - COALESCE(f.surviving_quantity, 0)) * COALESCE(d.deuterium_cost, 0))::numeric AS deuterium_lost
FROM initial_units AS i
LEFT JOIN final_units AS f
    ON f.participant_id = i.participant_id AND f.side = i.side AND f.unit_id = i.unit_id
LEFT JOIN public.defense_definitions AS d ON d.id = i.unit_id
ORDER BY i.participant_id, i.side, i.unit_id;
$defense_losses$;

revoke all on function public.calculate_combat_defense_losses(uuid) from public, anon, authenticated;

-- 2) participant-aware unit initialisation (identical output for one participant)
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

    select count(*)::integer into v_count from public.combat_individual_units
    where battle_id=p_battle_id and round_number=1;
    return v_count;
end;
$init_units$;

-- 3) re-apply the Phase 1 hardening to the new resolver signature
revoke all on function public.resolve_pending_target_damage(uuid, integer, uuid, text, text, text, integer)
  from public, anon, authenticated;

-- Post-conditions
do $p4a3$
begin
  if not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='calculate_combat_ship_losses' and prosrc like '%i.participant_id%')
     or not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='calculate_combat_defense_losses' and prosrc like '%i.participant_id%') then
    raise exception 'P4A-3: loss readers are not participant-aware';
  end if;

  if not exists (select 1 from pg_proc where pronamespace='public'::regnamespace
                   and proname='initialize_individual_combat_units'
                   and prosrc like '%from public.combat_battle_participants part%') then
    raise exception 'P4A-3: unit initialiser does not iterate attacker participants';
  end if;

  if has_function_privilege('authenticated','public.resolve_pending_target_damage(uuid,integer,uuid,text,text,text,integer)','EXECUTE')
     or has_function_privilege('anon','public.resolve_pending_target_damage(uuid,integer,uuid,text,text,text,integer)','EXECUTE')
     or has_function_privilege('authenticated','public.calculate_combat_ship_losses(uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.calculate_combat_defense_losses(uuid)','EXECUTE') then
    raise exception 'P4A-3: internal combat EXECUTE permissions were not re-hardened';
  end if;
end
$p4a3$;
