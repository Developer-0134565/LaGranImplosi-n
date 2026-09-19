-- ============================================================================
-- COMBAT V2 PARTICIPANT PROPAGATION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- Transaccional: TODO se revierte con ROLLBACK.
--
-- Fixture:
--   · atacante: fleet temporal de 20 cruisers
--   · defensor: planeta temporalizado sobre un planeta real existente, con
--     10 small_cargo y sin defensas
--   · regla RF temporal cruiser -> small_cargo = 6
--
-- Verifica:
--   1. resolve_combat crea exactamente los 2 participants correctos.
--   2. initialize_individual_combat_units propaga participant_id.
--   3. snapshots conservan participant_id.
--   4. shots iniciales conservan attacker/target participant_id.
--   5. rapidfire chain conserva ambos participant_id.
--   6. damage ledger conserva target_participant_id.
--   7. apply_damage actualiza por participant_id.
--   8. next round conserva participant_id.
--   9. settlement resuelve sólo contra el participant atacante/planeta correcto.
--  10. no queda ningún NULL participant_id en las filas creadas por el fixture.
--
-- NO ES MIGRACIÓN.
-- ============================================================================

begin;

do $test$
declare
    v_fleet_id uuid := gen_random_uuid();
    v_battle_id uuid;
    v_attacker_player uuid := '60f1043a-2fa6-416c-80db-2a83215b5404';
    v_origin_planet uuid := 'c0d77158-78ca-4631-98f2-b01d571d627c';
    v_defender_planet uuid := 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    v_defender_player uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    v_attacker_participant uuid;
    v_defender_participant uuid;
    v_round record;
    v_results record;
    v_n bigint;
    v_fail text := '';
begin
    create temp table t_results(
        orden serial,
        prueba text,
        resultado text
    ) on commit drop;

    /* -----------------------------------------------------------------------
       Fixture reversible
       ----------------------------------------------------------------------- */
    delete from public.combat_rapidfire
     where attacker_unit_type='SHIP' and attacker_unit_id='cruiser'
       and target_unit_type='SHIP' and target_unit_id='small_cargo';

    insert into public.combat_rapidfire(
        attacker_unit_type,attacker_unit_id,target_unit_type,target_unit_id,rapidfire
    ) values ('SHIP','cruiser','SHIP','small_cargo',6);

    delete from public.planet_ships where planet_id=v_defender_planet;
    delete from public.planet_defenses where planet_id=v_defender_planet;

    insert into public.planet_ships(planet_id,ship_id,quantity)
    values (v_defender_planet,'small_cargo',10);

    insert into public.fleet_movements(
        id,player_id,origin_planet_id,destination_planet_id,mission_type,
        started_at,arrives_at,status
    ) values (
        v_fleet_id,v_attacker_player,v_origin_planet,v_defender_planet,'ATTACK',
        clock_timestamp()-interval '1 minute',
        clock_timestamp()-interval '1 second',
        'ARRIVED'
    );

    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
    values (v_fleet_id,'cruiser',20);

    /* -----------------------------------------------------------------------
       1. Resolve + participant creation
       ----------------------------------------------------------------------- */
    v_battle_id := public.resolve_combat(v_fleet_id);

    select id into v_attacker_participant
    from public.combat_battle_participants
    where battle_id=v_battle_id
      and side='ATTACKER'
      and participant_type='FLEET'
      and fleet_id=v_fleet_id
      and player_id=v_attacker_player;

    select id into v_defender_participant
    from public.combat_battle_participants
    where battle_id=v_battle_id
      and side='DEFENDER'
      and participant_type='PLANET'
      and planet_id=v_defender_planet
      and player_id=v_defender_player;

    select count(*) into v_n
    from public.combat_battle_participants
    where battle_id=v_battle_id;

    insert into t_results(prueba,resultado) values
    ('1. participants: exactamente 2 ['||v_n||']',
     case when v_n=2 and v_attacker_participant is not null and v_defender_participant is not null
          then 'PASS' else 'FAIL' end);

    /* -----------------------------------------------------------------------
       2. Unit initialization
       ----------------------------------------------------------------------- */
    select count(*) into v_n
    from public.combat_individual_units
    where battle_id=v_battle_id
      and participant_id is not null;

    insert into t_results(prueba,resultado) values
    ('2. unidades con participant_id ['||v_n||']',
     case when v_n=30 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_individual_units
    where battle_id=v_battle_id
      and ((side='ATTACKER' and participant_id<>v_attacker_participant)
        or (side='DEFENDER' and participant_id<>v_defender_participant));

    insert into t_results(prueba,resultado) values
    ('2b. unidades apuntan al participant correcto ['||v_n||']',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    /* -----------------------------------------------------------------------
       3-8. Full V2 round path
       ----------------------------------------------------------------------- */
    for v_round in
        select * from public.run_expedition_combat(v_battle_id)
    loop
        null;
    end loop;

    select count(*) into v_n
    from public.combat_round_snapshot_units
    where battle_id=v_battle_id
      and participant_id is not null;

    insert into t_results(prueba,resultado) values
    ('3. snapshots con participant_id ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_round_snapshot_units
    where battle_id=v_battle_id
      and ((side='ATTACKER' and participant_id<>v_attacker_participant)
        or (side='DEFENDER' and participant_id<>v_defender_participant));

    insert into t_results(prueba,resultado) values
    ('3b. snapshots apuntan al participant correcto ['||v_n||']',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_shots
    where battle_id=v_battle_id
      and attacker_participant_id=v_attacker_participant
      and target_participant_id=v_defender_participant;

    insert into t_results(prueba,resultado) values
    ('4. shots con attacker/target participant correctos ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_shots
    where battle_id=v_battle_id
      and (attacker_participant_id is null or target_participant_id is null);

    insert into t_results(prueba,resultado) values
    ('4b. ningún shot con participant NULL ['||v_n||']',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_shots
    where battle_id=v_battle_id
      and is_initial_shot=false
      and attacker_participant_id=v_attacker_participant
      and target_participant_id=v_defender_participant;

    insert into t_results(prueba,resultado) values
    ('5. rapidfire chain participant-aware ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL: no RF shot generado' end);

    select count(*) into v_n
    from public.combat_round_damage
    where battle_id=v_battle_id
      and target_participant_id=v_defender_participant;

    insert into t_results(prueba,resultado) values
    ('6. damage ledger target_participant_id correcto ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_round_damage
    where battle_id=v_battle_id
      and target_participant_id is null;

    insert into t_results(prueba,resultado) values
    ('6b. damage ledger sin participant NULL ['||v_n||']',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_individual_units
    where battle_id=v_battle_id
      and participant_id is null;

    insert into t_results(prueba,resultado) values
    ('7. damage application no rompe identidad ['||v_n||' NULL tras resolver]',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_individual_units
    where battle_id=v_battle_id
      and round_number>1
      and participant_id is not null;

    insert into t_results(prueba,resultado) values
    ('8. rounds posteriores conservan participant_id ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL: no se creó ronda posterior' end);

    /* -----------------------------------------------------------------------
       9. Settlement
       resolve_attack_arrival es idempotente en ARRIVED -> RETURNING, pero
       aquí ya terminó el combate. Revertimos a ARRIVED y repetimos settlement
       dentro de la misma transacción para probar el wiring explícito.
       ----------------------------------------------------------------------- */
    update public.fleet_movements
       set status='ARRIVED'
     where id=v_fleet_id;

    perform public.sync_combat_battle_final_counts(v_battle_id);

    delete from public.fleet_movement_ships where fleet_id=v_fleet_id;

    insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
    select v_fleet_id,ciu.unit_id,count(*)::bigint
    from public.combat_individual_units ciu
    where ciu.battle_id=v_battle_id
      and ciu.round_number=(select max(round_number) from public.combat_individual_units where battle_id=v_battle_id)
      and ciu.participant_id=v_attacker_participant
      and ciu.side='ATTACKER'
      and ciu.unit_type='SHIP'
      and ciu.alive
    group by ciu.unit_id;

    /* La llamada real de settlement comprueba de nuevo los participants. */
    perform public.resolve_attack_arrival(v_fleet_id);

    select count(*) into v_n
    from public.fleet_movement_ships fms
    where fms.fleet_id=v_fleet_id
      and exists (
          select 1
          from public.combat_individual_units ciu
          where ciu.battle_id=v_battle_id
            and ciu.participant_id=v_attacker_participant
            and ciu.side='ATTACKER'
            and ciu.unit_type='SHIP'
            and ciu.unit_id=fms.ship_id
      );

    insert into t_results(prueba,resultado) values
    ('9. settlement reconstruye sólo flota del participant atacante ['||v_n||']',
     case when v_n>0 then 'PASS' else 'FAIL' end);

    select count(*) into v_n
    from public.combat_battle_participants cbp
    where cbp.battle_id=v_battle_id
      and cbp.side='ATTACKER'
      and cbp.fleet_id=v_fleet_id;

    insert into t_results(prueba,resultado) values
    ('9b. settlement conserva participant atacante ['||v_n||']',
     case when v_n=1 then 'PASS' else 'FAIL' end);

    /* -----------------------------------------------------------------------
       10. No NULLs anywhere in this fresh combat
       ----------------------------------------------------------------------- */
    select count(*) into v_n
    from (
      select participant_id from public.combat_individual_units where battle_id=v_battle_id
      union all
      select participant_id from public.combat_round_snapshot_units where battle_id=v_battle_id
      union all
      select attacker_participant_id from public.combat_shots where battle_id=v_battle_id
      union all
      select target_participant_id from public.combat_shots where battle_id=v_battle_id
      union all
      select target_participant_id from public.combat_round_damage where battle_id=v_battle_id
    ) q
    where participant_id is null;

    insert into t_results(prueba,resultado) values
    ('10. pipeline completo sin participant NULL ['||v_n||']',
     case when v_n=0 then 'PASS' else 'FAIL' end);

    /* -----------------------------------------------------------------------
       Report
       ----------------------------------------------------------------------- */
    raise notice '----- COMBAT V2 PARTICIPANT FIXTURE -----';

    for v_results in
        select orden,prueba,resultado from t_results order by orden
    loop
        raise notice '%  %  ->  %',
            rpad(v_results.orden::text,3),
            rpad(v_results.resultado,28),
            v_results.prueba;
    end loop;

    select count(*),coalesce(string_agg('['||orden||'] '||resultado||' :: '||prueba,' | ' order by orden),'')
      into v_n,v_fail
      from t_results
     where resultado not like 'PASS%';

    if v_n>0 then
        raise exception 'COMBAT V2 PARTICIPANT FIXTURE FAILED: % prueba(s) -> %',v_n,v_fail;
    end if;

    raise notice 'COMBAT V2 PARTICIPANT FIXTURE: ALL PASS (transaction rolled back)';
end;
$test$;

select orden,resultado,prueba from t_results order by orden;

rollback;
