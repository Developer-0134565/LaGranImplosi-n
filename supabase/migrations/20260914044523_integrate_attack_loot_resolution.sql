create or replace function public.resolve_attack_arrival(p_fleet_id uuid)
returns uuid
language plpgsql
as $$
declare
    v_fleet public.fleet_movements%rowtype;
    v_battle_id uuid;
    v_last_round integer;
    v_duration interval;
begin
    select * into v_fleet from public.fleet_movements where id=p_fleet_id for update;
    if not found then raise exception 'Fleet % no existe',p_fleet_id; end if;
    if v_fleet.mission_type <> 'ATTACK' then raise exception 'Fleet % no es ATTACK',p_fleet_id; end if;
    if v_fleet.status not in ('ARRIVED','RETURNING','COMPLETED') then
      raise exception 'Fleet % no está lista para resolver ataque. Estado: %',p_fleet_id,v_fleet.status;
    end if;

    select cb.id into v_battle_id
    from public.combat_battles cb
    where cb.fleet_id=p_fleet_id
    order by cb.created_at
    limit 1 for update;

    if v_battle_id is null then v_battle_id:=public.resolve_combat(p_fleet_id); end if;

    if v_fleet.status <> 'ARRIVED' then return v_battle_id; end if;

    if not exists(select 1 from public.combat_battles where id=v_battle_id and finished_at is not null) then
      perform public.run_expedition_combat(v_battle_id);
    end if;

    select max(round_number) into v_last_round
    from public.combat_individual_units where battle_id=v_battle_id;
    if v_last_round is null then raise exception 'Battle % finished without rounds',v_battle_id; end if;

    perform public.sync_combat_battle_final_counts(v_battle_id);

    delete from public.fleet_movement_ships where fleet_id=p_fleet_id;
    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
    select p_fleet_id,ciu.unit_id,count(*)::bigint
    from public.combat_individual_units ciu
    where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
      and ciu.side='ATTACKER' and ciu.unit_type='SHIP' and ciu.alive
    group by ciu.unit_id;

    update public.planet_ships ps
    set quantity=coalesce(src.quantity,0)
    from (
      select ciu.unit_id,count(*)::bigint quantity
      from public.combat_individual_units ciu
      where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
        and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.alive
      group by ciu.unit_id
    ) src
    where ps.planet_id=v_fleet.destination_planet_id and ps.ship_id=src.unit_id;

    update public.planet_ships ps set quantity=0
    where ps.planet_id=v_fleet.destination_planet_id
      and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.unit_id=ps.ship_id)
      and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='SHIP' and ciu.unit_id=ps.ship_id and ciu.alive);

    update public.planet_defenses pd
    set quantity=coalesce(src.quantity,0)
    from (
      select ciu.unit_id,count(*)::bigint quantity
      from public.combat_individual_units ciu
      where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round
        and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.alive
      group by ciu.unit_id
    ) src
    where pd.planet_id=v_fleet.destination_planet_id and pd.defense_id=src.unit_id;

    update public.planet_defenses pd set quantity=0
    where pd.planet_id=v_fleet.destination_planet_id
      and exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id)
      and not exists(select 1 from public.combat_individual_units ciu where ciu.battle_id=v_battle_id and ciu.round_number=v_last_round and ciu.side='DEFENDER' and ciu.unit_type='DEFENSE' and ciu.unit_id=pd.defense_id and ciu.alive);

    /* Loot is applied after surviving attacker cargo is rebuilt and before
       ARRIVED -> RETURNING. This makes that transition the transaction barrier. */
    perform * from public.apply_attack_loot(v_battle_id);

    perform * from public.repair_defenses_after_combat(v_battle_id);
    perform public.create_combat_debris(v_battle_id);

    v_duration:=v_fleet.arrives_at-v_fleet.started_at;
    update public.fleet_movements
    set status='RETURNING',returns_at=arrives_at+v_duration
    where id=p_fleet_id and status='ARRIVED';

    return v_battle_id;
end;
$$;
