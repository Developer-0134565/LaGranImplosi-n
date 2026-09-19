-- Forward-only combat participant propagation for the existing V2 single-attacker path.
-- No combat rules are changed. Historical rows remain untouched; new battles created through
-- resolve_combat() receive explicit ATTACKER/FLEET and DEFENDER/PLANET participants.

create or replace function public.resolve_combat(p_fleet_id uuid)
returns uuid
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_battle_id uuid;
    v_fleet public.fleet_movements%rowtype;
    v_defender_player_id uuid;
    v_attacker_units bigint:=0;
    v_defender_ship_units bigint:=0;
    v_defense_units bigint:=0;
    v_defender_units bigint:=0;
    v_attacker_attack numeric:=0; v_attacker_shield numeric:=0; v_attacker_hull numeric:=0;
    v_defender_ship_attack numeric:=0; v_defender_ship_shield numeric:=0; v_defender_ship_hull numeric:=0;
    v_defense_attack numeric:=0; v_defense_shield numeric:=0; v_defense_hull numeric:=0;
    v_defender_attack numeric:=0; v_defender_shield numeric:=0; v_defender_hull numeric:=0;
begin
    select * into v_fleet from public.fleet_movements where id=p_fleet_id for update;
    if not found then raise exception 'Fleet % no existe',p_fleet_id; end if;
    if v_fleet.mission_type <> 'ATTACK' then raise exception 'Fleet % no es una misión ATTACK',p_fleet_id; end if;
    if v_fleet.destination_planet_id is null then raise exception 'La flota % no tiene planeta objetivo',p_fleet_id; end if;

    select cb.id into v_battle_id from public.combat_battles cb
    where cb.fleet_id=p_fleet_id order by cb.created_at limit 1 for update;
    if v_battle_id is not null then return v_battle_id; end if;

    select p.player_id into v_defender_player_id from public.planets p where p.id=v_fleet.destination_planet_id;
    if v_defender_player_id is null then raise exception 'El planeta defensor % no tiene jugador',v_fleet.destination_planet_id; end if;

    select coalesce(sum(sd.attack*fms.quantity),0),coalesce(sum(sd.shield*fms.quantity),0),
           coalesce(sum(sd.hull*fms.quantity),0),coalesce(sum(fms.quantity),0)
    into v_attacker_attack,v_attacker_shield,v_attacker_hull,v_attacker_units
    from public.fleet_movement_ships fms join public.ship_definitions sd on sd.id=fms.ship_id
    where fms.fleet_id=p_fleet_id;
    if v_attacker_units<=0 then raise exception 'La flota % no contiene naves',p_fleet_id; end if;

    select coalesce(sum(sd.attack*ps.quantity),0),coalesce(sum(sd.shield*ps.quantity),0),
           coalesce(sum(sd.hull*ps.quantity),0),coalesce(sum(ps.quantity),0)
    into v_defender_ship_attack,v_defender_ship_shield,v_defender_ship_hull,v_defender_ship_units
    from public.planet_ships ps join public.ship_definitions sd on sd.id=ps.ship_id
    where ps.planet_id=v_fleet.destination_planet_id and ps.quantity>0;

    select coalesce(sum(dd.attack*pd.quantity),0),coalesce(sum(dd.shield*pd.quantity),0),
           coalesce(sum(dd.hull*pd.quantity),0),coalesce(sum(pd.quantity),0)
    into v_defense_attack,v_defense_shield,v_defense_hull,v_defense_units
    from public.planet_defenses pd join public.defense_definitions dd on dd.id=pd.defense_id
    where pd.planet_id=v_fleet.destination_planet_id and pd.quantity>0;

    v_defender_units:=v_defender_ship_units+v_defense_units;
    v_defender_attack:=v_defender_ship_attack+v_defense_attack;
    v_defender_shield:=v_defender_ship_shield+v_defense_shield;
    v_defender_hull:=v_defender_ship_hull+v_defense_hull;

    insert into public.combat_battles(
      fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,
      defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,
      defender_combat_units_before,defender_combat_units_after)
    values(p_fleet_id,v_fleet.player_id,v_fleet.destination_planet_id,v_attacker_units,v_attacker_units,
      v_defender_ship_units,v_defender_ship_units,v_defense_units,v_defense_units,v_defender_units,v_defender_units)
    returning id into v_battle_id;

    insert into public.combat_battle_participants(
      battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
    values(v_battle_id,'ATTACKER','FLEET',p_fleet_id,null,v_fleet.player_id,v_fleet.origin_planet_id,v_fleet.mission_type);

    insert into public.combat_battle_participants(
      battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
    values(v_battle_id,'DEFENDER','PLANET',null,v_fleet.destination_planet_id,v_defender_player_id,null,null);

    perform public.initialize_individual_combat_units(v_battle_id);
    return v_battle_id;
end;
$function$;

create or replace function public.initialize_individual_combat_units(p_battle_id uuid)
returns integer language plpgsql
set search_path to 'public','pg_temp'
as $function$
declare
    v_fleet_id uuid; v_planet_id uuid; v_attacker_player_id uuid; v_defender_player_id uuid;
    v_attacker_participant_id uuid; v_defender_participant_id uuid; v_count integer;
begin
    select cb.fleet_id,cb.defender_planet_id,cb.attacker_player_id
    into v_fleet_id,v_planet_id,v_attacker_player_id from public.combat_battles cb where cb.id=p_battle_id;
    if v_fleet_id is null then raise exception 'Batalla % no encontrada',p_battle_id; end if;
    select p.player_id into v_defender_player_id from public.planets p where p.id=v_planet_id;

    select id into v_attacker_participant_id from public.combat_battle_participants
    where battle_id=p_battle_id and side='ATTACKER' and participant_type='FLEET' and fleet_id=v_fleet_id;
    select id into v_defender_participant_id from public.combat_battle_participants
    where battle_id=p_battle_id and side='DEFENDER' and participant_type='PLANET' and planet_id=v_planet_id;
    if v_attacker_participant_id is null or v_defender_participant_id is null then
      raise exception 'Battle % missing combat participants',p_battle_id;
    end if;

    insert into public.combat_individual_units(
      battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
      attack,shield_max,shield_current,structural_integrity,hull_max,hull_current)
    select p_battle_id,1,v_attacker_participant_id,'ATTACKER','SHIP',fms.ship_id,gs.n,
      public.get_combat_ship_attack(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_shield(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_shield(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id)*10,
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id),
      public.get_combat_ship_hull(v_attacker_player_id,fms.ship_id)
    from public.fleet_movement_ships fms cross join lateral generate_series(1,fms.quantity) gs(n)
    where fms.fleet_id=v_fleet_id;

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
$function$;

create or replace function public.create_combat_round_snapshot(p_battle_id uuid,p_round_number integer)
returns table(units_created bigint,attacker_units bigint,defender_units bigint)
language plpgsql set search_path to 'public','pg_temp'
as $function$
begin
  insert into public.combat_round_snapshot_units(
    battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
    attack,shield_max,shield_start,hull_max,hull_start,alive_start)
  select cui.battle_id,cui.round_number,cui.participant_id,cui.side,cui.unit_type,cui.unit_id,cui.unit_number,
    cui.attack,cui.shield_max,cui.shield_current,cui.hull_max,cui.hull_current,cui.alive
  from public.combat_individual_units cui
  where cui.battle_id=p_battle_id and cui.round_number=p_round_number and cui.alive=true
  on conflict(battle_id,round_number,side,unit_type,unit_id,unit_number) do nothing;

  return query select count(*)::bigint,count(*) filter(where side='ATTACKER')::bigint,
    count(*) filter(where side='DEFENDER')::bigint
  from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number;
end;
$function$;

create or replace function public.generate_combat_round_v2(p_battle_id uuid,p_round_number integer)
returns table(shots_created bigint,attacker_units bigint,defender_units bigint)
language plpgsql set search_path to 'public','pg_temp'
as $function$
declare
  v_shots bigint; v_attackers bigint; v_defenders bigint; v_attacker record;
  v_target public.combat_round_snapshot_units%rowtype; v_rf numeric; v_probability numeric;
  v_roll numeric; v_triggered boolean; v_shot_number integer;
begin
  if not exists(select 1 from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number)
  then raise exception 'Combat round snapshot not found: battle %, round %',p_battle_id,p_round_number; end if;

  if exists(select 1 from public.combat_shots where battle_id=p_battle_id and round_number=p_round_number) then
    select count(*) into v_shots from public.combat_shots where battle_id=p_battle_id and round_number=p_round_number;
    select count(*) into v_attackers from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number and side='ATTACKER' and alive_start;
    select count(*) into v_defenders from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number and side='DEFENDER' and alive_start;
    return query select v_shots,v_attackers,v_defenders; return;
  end if;

  for v_attacker in select a.* from public.combat_round_snapshot_units a
    where a.battle_id=p_battle_id and a.round_number=p_round_number and a.alive_start order by random()
  loop
    select t.* into v_target from public.combat_round_snapshot_units t
    where t.battle_id=p_battle_id and t.round_number=p_round_number and t.side<>v_attacker.side and t.alive_start
    order by random() limit 1;
    if not found then continue; end if;

    select coalesce((select cr.rapidfire from public.combat_rapidfire cr
      where cr.attacker_unit_type=v_attacker.unit_type and cr.attacker_unit_id=v_attacker.unit_id
        and cr.target_unit_type=v_target.unit_type and cr.target_unit_id=v_target.unit_id limit 1),1) into v_rf;
    if v_rf>1 then v_probability:=1-(1/v_rf); v_roll:=random(); v_triggered:=v_roll<v_probability;
    else v_probability:=0; v_roll:=1; v_triggered:=false; end if;

    select coalesce(max(cs.shot_number),0)+1 into v_shot_number from public.combat_shots cs
    where cs.battle_id=p_battle_id and cs.round_number=p_round_number;

    insert into public.combat_shots(
      battle_id,round_number,shot_number,attacker_participant_id,target_participant_id,
      attacker_side,attacker_unit_type,attacker_unit_id,attacker_unit_number,
      target_unit_type,target_unit_id,target_unit_number,attack_value,target_shield_before,
      raw_damage,effective_damage,shield_damage,hull_damage,target_destroyed,
      rapidfire_value,rapidfire_triggered,rapidfire_probability,rapidfire_roll,is_initial_shot)
    values(p_battle_id,p_round_number,v_shot_number,v_attacker.participant_id,v_target.participant_id,
      v_attacker.side,v_attacker.unit_type,v_attacker.unit_id,v_attacker.unit_number,
      v_target.unit_type,v_target.unit_id,v_target.unit_number,v_attacker.attack,v_target.shield_start,
      0,0,0,0,false,v_rf,v_triggered,v_probability,v_roll,true);
  end loop;

  select count(*) into v_shots from public.combat_shots where battle_id=p_battle_id and round_number=p_round_number;
  select count(*) into v_attackers from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number and side='ATTACKER' and alive_start;
  select count(*) into v_defenders from public.combat_round_snapshot_units where battle_id=p_battle_id and round_number=p_round_number and side='DEFENDER' and alive_start;
  return query select v_shots,v_attackers,v_defenders;
end;
$function$;

create or replace function public.expand_rapidfire_chain_v2(p_battle_id uuid,p_round_number integer,p_source_shot_number integer)
returns table(shots_added integer,last_shot_number integer)
language plpgsql set search_path to 'public','pg_temp'
as $function$
declare
  v_previous public.combat_shots%rowtype; v_attacker public.combat_round_snapshot_units%rowtype;
  v_target public.combat_round_snapshot_units%rowtype; v_rf numeric; v_probability numeric;
  v_roll numeric; v_triggered boolean; v_next_shot integer;
begin
  select cs.* into v_previous from public.combat_shots cs
  where cs.battle_id=p_battle_id and cs.round_number=p_round_number and cs.shot_number=p_source_shot_number;
  if not found then raise exception 'Previous shot not found: %',p_source_shot_number; end if;
  if v_previous.rapidfire_triggered is not true then return query select 0,p_source_shot_number; return; end if;

  select cru.* into v_attacker from public.combat_round_snapshot_units cru
  where cru.battle_id=p_battle_id and cru.round_number=p_round_number
    and cru.participant_id=v_previous.attacker_participant_id and cru.side=v_previous.attacker_side
    and cru.unit_type=v_previous.attacker_unit_type and cru.unit_id=v_previous.attacker_unit_id
    and cru.unit_number=v_previous.attacker_unit_number and cru.alive_start limit 1;
  if not found then raise exception 'Attacker not found in snapshot: %/%/%',v_previous.attacker_unit_type,v_previous.attacker_unit_id,v_previous.attacker_unit_number; end if;

  select cru.* into v_target from public.combat_round_snapshot_units cru
  where cru.battle_id=p_battle_id and cru.round_number=p_round_number
    and cru.participant_id=v_previous.target_participant_id and cru.side<>v_previous.attacker_side
    and cru.alive_start order by random() limit 1;
  if not found then return query select 0,p_source_shot_number; return; end if;

  select coalesce((select cr.rapidfire from public.combat_rapidfire cr
    where cr.attacker_unit_type=v_attacker.unit_type and cr.attacker_unit_id=v_attacker.unit_id
      and cr.target_unit_type=v_target.unit_type and cr.target_unit_id=v_target.unit_id limit 1),1) into v_rf;
  if v_rf>1 then v_probability:=1-(1/v_rf); v_roll:=random(); v_triggered:=v_roll<v_probability;
  else v_probability:=0; v_roll:=1; v_triggered:=false; end if;

  select coalesce(max(cs.shot_number),0)+1 into v_next_shot from public.combat_shots cs
  where cs.battle_id=p_battle_id and cs.round_number=p_round_number;

  insert into public.combat_shots(
    battle_id,round_number,shot_number,attacker_participant_id,target_participant_id,
    attacker_side,attacker_unit_type,attacker_unit_id,attacker_unit_number,
    target_unit_type,target_unit_id,target_unit_number,attack_value,target_shield_before,
    raw_damage,effective_damage,shield_damage,hull_damage,target_destroyed,
    rapidfire_value,rapidfire_triggered,rapidfire_probability,rapidfire_roll,is_initial_shot)
  values(p_battle_id,p_round_number,v_next_shot,v_attacker.participant_id,v_target.participant_id,
    v_previous.attacker_side,v_attacker.unit_type,v_attacker.unit_id,v_attacker.unit_number,
    v_target.unit_type,v_target.unit_id,v_target.unit_number,v_attacker.attack,v_target.shield_start,
    0,0,0,0,false,v_rf,v_triggered,v_probability,v_roll,false);
  return query select 1,v_next_shot;
end;
$function$;

create or replace function public.calculate_combat_round_pending_damage(p_battle_id uuid,p_round_number integer)
returns table(shots_processed bigint,damage_rows bigint)
language plpgsql set search_path to 'public','pg_temp'
as $function$
begin
  delete from public.combat_round_damage where battle_id=p_battle_id and round_number=p_round_number;
  insert into public.combat_round_damage(
    battle_id,round_number,target_participant_id,target_side,target_unit_type,target_unit_id,target_unit_number,
    source_shot_number,attack_value,shield_damage,hull_damage)
  select s.battle_id,s.round_number,s.target_participant_id,t.side,t.unit_type,t.unit_id,t.unit_number,
    s.shot_number,s.attack_value,0,0
  from public.combat_shots s
  join public.combat_round_snapshot_units t on t.battle_id=s.battle_id and t.round_number=s.round_number
    and t.participant_id=s.target_participant_id and t.side<>s.attacker_side
    and t.unit_type=s.target_unit_type and t.unit_id=s.target_unit_id and t.unit_number=s.target_unit_number
  where s.battle_id=p_battle_id and s.round_number=p_round_number;
  select count(*)::bigint,count(*)::bigint into shots_processed,damage_rows
  from public.combat_round_damage where battle_id=p_battle_id and round_number=p_round_number;
  return next;
end;
$function$;

create or replace function public.apply_combat_round_damage(p_battle_id uuid,p_round_number integer)
returns table(units_updated bigint,units_destroyed bigint)
language plpgsql set search_path to 'public','pg_temp'
as $function$
declare v_unit record; v_updated bigint:=0; v_destroyed bigint:=0;
begin
  for v_unit in
    select d.target_participant_id,d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number,
      sum(d.shield_damage) shield_damage,sum(d.hull_damage) hull_damage,bool_or(d.exploded) exploded
    from public.combat_round_damage d where d.battle_id=p_battle_id and d.round_number=p_round_number
    group by d.target_participant_id,d.target_side,d.target_unit_type,d.target_unit_id,d.target_unit_number
  loop
    update public.combat_individual_units cui
    set shield_current=case when v_unit.exploded then 0 else greatest(cui.shield_current-v_unit.shield_damage,0) end,
        hull_current=case when v_unit.exploded then 0 else greatest(cui.hull_current-v_unit.hull_damage,0) end,
        alive=case when v_unit.exploded then false else greatest(cui.hull_current-v_unit.hull_damage,0)>0 end
    where cui.battle_id=p_battle_id and cui.round_number=p_round_number
      and cui.participant_id=v_unit.target_participant_id and cui.side=v_unit.target_side
      and cui.unit_type=v_unit.target_unit_type and cui.unit_id=v_unit.target_unit_id
      and cui.unit_number=v_unit.target_unit_number;
    if found then v_updated:=v_updated+1; end if;
  end loop;
  select count(*) into v_destroyed from public.combat_individual_units
  where battle_id=p_battle_id and round_number=p_round_number and alive=false;
  units_updated:=v_updated; units_destroyed:=v_destroyed; return next;
end;
$function$;

create or replace function public.create_combat_next_round(p_battle_id uuid,p_previous_round integer)
returns table(next_round integer,units_created bigint,attacker_units bigint,defender_units bigint)
language plpgsql set search_path to 'public','pg_temp'
as $function$
declare v_next_round integer:=p_previous_round+1;
begin
  if p_previous_round>=6 then raise exception 'No se puede crear una ronda posterior a la 6'; end if;
  if exists(select 1 from public.combat_individual_units where battle_id=p_battle_id and round_number=v_next_round) then
    return query select v_next_round,count(*)::bigint,count(*) filter(where side='ATTACKER')::bigint,count(*) filter(where side='DEFENDER')::bigint
    from public.combat_individual_units where battle_id=p_battle_id and round_number=v_next_round; return;
  end if;
  insert into public.combat_individual_units(
    battle_id,round_number,participant_id,side,unit_type,unit_id,unit_number,
    attack,shield_max,shield_current,structural_integrity,hull_max,hull_current,alive)
  select cui.battle_id,v_next_round,cui.participant_id,cui.side,cui.unit_type,cui.unit_id,cui.unit_number,
    cui.attack,cui.shield_max,cui.shield_max,cui.structural_integrity,cui.hull_max,cui.hull_current,true
  from public.combat_individual_units cui
  where cui.battle_id=p_battle_id and cui.round_number=p_previous_round and cui.alive=true;
  return query select v_next_round,count(*)::bigint,count(*) filter(where side='ATTACKER')::bigint,count(*) filter(where side='DEFENDER')::bigint
  from public.combat_individual_units where battle_id=p_battle_id and round_number=v_next_round;
end;
$function$;

create or replace function public.resolve_attack_arrival(p_fleet_id uuid)
returns uuid language plpgsql
set search_path to 'pg_catalog','public'
as $function$
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
$function$;