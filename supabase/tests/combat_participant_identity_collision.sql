-- ============================================================================
-- COMBAT ENGINE PHASE 4A — PARTICIPANT IDENTITY COLLISION FIXTURE
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Proves the reason Phase 4A exists: one battle can carry TWO attacking fleets
-- that field the SAME unit type with the SAME unit number, and the engine keeps
-- them as two distinct units through snapshots, targeting, damage and losses.
--
--   before Phase 4A: the legacy unique keys (battle, round, side, unit_type,
--   unit_id, unit_number) made "participant A cruiser #1" and "participant B
--   cruiser #1" the SAME row, and combat_round_snapshot_units silently dropped
--   the second one through ON CONFLICT DO NOTHING.
--
-- Scenario 1 exercises the real pipeline with two ATTACKER/FLEET participants
-- (20 cruisers + 5 cruisers) against one planet.
-- Scenario 2 resolves one controlled damage row per participant through
-- resolve_pending_target_damage and proves each call resolves ITS OWN unit and
-- that a wrong participant is rejected.
--
-- ROLLBACK SAFETY: every row created here lives inside a nested PL/pgSQL block
-- undone by a sentinel exception, so no battle, unit, snapshot, ledger or fleet
-- survives. No player, planet or resource is created or modified.
-- ============================================================================

begin;

drop table if exists t_combat_participant_identity_results;
create temp table t_combat_participant_identity_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid; v_target uuid; v_def_player uuid;
    v_fleet_a uuid := gen_random_uuid(); v_fleet_b uuid := gen_random_uuid(); v_battle uuid;
    v_fleet_a2 uuid := gen_random_uuid(); v_fleet_b2 uuid := gen_random_uuid(); v_battle2 uuid;
    v_part_a uuid; v_part_b uuid; v_part_planet uuid;
    v_part_a2 uuid; v_part_b2 uuid; v_part_planet2 uuid;
    v_rows bigint; v_rows2 bigint; v_rows3 bigint;
    v_ok boolean; v_fail integer := 0; v_lines text := ''; r record; v_raised boolean := false;
begin
    begin
        select pl.id, pl.user_id, p.id, p.universe_id
          into v_player, v_user, v_origin, v_universe
        from public.planets p
        join public.players pl on pl.id = p.player_id
        where pl.player_type = 'HUMAN' and pl.user_id is not null and p.is_destroyed = false
        order by (pl.username like 'DevPlayer%'), p.created_at, p.id
        limit 1;

        if v_origin is null then
            raise exception 'PHASE4A_FIXTURE_ABORT: no HUMAN player with a usable planet';
        end if;

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        select p2.id, p2.player_id into v_target, v_def_player
        from public.planets p2
        where p2.universe_id = v_universe and p2.is_destroyed = false
          and p2.player_id <> v_player and p2.id <> v_origin
        order by p2.galaxy, p2.system, p2.position, p2.id
        limit 1;

        if v_target is null then
            raise exception 'PHASE4A_FIXTURE_ABORT: no candidate defender planet';
        end if;

        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

        -- ================= SCENARIO 1 — two attacker fleets =================
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status) values
          (v_fleet_a, v_player, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED'),
          (v_fleet_b, v_player, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_fleet_a,'cruiser',20),(v_fleet_b,'cruiser',5);

        insert into public.combat_battles(
          fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,
          defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,
          defender_combat_units_before,defender_combat_units_after,draw)
        values (v_fleet_a,v_player,v_target,0,0,0,0,0,0,0,0,false) returning id into v_battle;

        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_battle,'ATTACKER','FLEET',v_fleet_a,null,v_player,v_origin,'ATTACK'),
               (v_battle,'ATTACKER','FLEET',v_fleet_b,null,v_player,v_origin,'ATTACK'),
               (v_battle,'DEFENDER','PLANET',null,v_target,v_def_player,null,null);

        perform public.initialize_individual_combat_units(v_battle);
        perform public.run_expedition_combat(v_battle);

        select id into v_part_a from public.combat_battle_participants where battle_id=v_battle and side='ATTACKER' and fleet_id=v_fleet_a;
        select id into v_part_b from public.combat_battle_participants where battle_id=v_battle and side='ATTACKER' and fleet_id=v_fleet_b;
        select id into v_part_planet from public.combat_battle_participants where battle_id=v_battle and side='DEFENDER' and participant_type='PLANET';

        -- T1 participants
        select count(*) into v_rows from public.combat_battle_participants where battle_id=v_battle;
        v_ok := v_rows = 3 and v_part_a is not null and v_part_b is not null and v_part_planet is not null;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T1 two attacker fleets + one planet are three participants (%s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T2 unit attribution
        select count(*) filter (where side='ATTACKER' and participant_id=v_part_a),
               count(*) filter (where side='ATTACKER' and participant_id=v_part_b),
               count(*) filter (where participant_id is null)
          into v_rows, v_rows2, v_rows3
        from public.combat_individual_units where battle_id=v_battle and round_number=1;
        v_ok := v_rows = 20 and v_rows2 = 5 and v_rows3 = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T2 units attributed per fleet (A=%s B=%s null=%s)', v_rows, v_rows2, v_rows3) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T3 the collision case: two distinct "cruiser #1" rows
        select count(*), count(distinct participant_id) into v_rows, v_rows2
        from public.combat_individual_units
        where battle_id=v_battle and round_number=1 and side='ATTACKER'
          and unit_type='SHIP' and unit_id='cruiser' and unit_number=1;
        v_ok := v_rows = 2 and v_rows2 = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T3 identical unit identity is two distinct units (%s rows / %s participants)', v_rows, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T4 no snapshot loss
        select count(*), count(distinct participant_id) into v_rows, v_rows2
        from public.combat_round_snapshot_units where battle_id=v_battle and round_number=1;
        select count(*) into v_rows3 from public.combat_round_snapshot_units
        where battle_id=v_battle and round_number=1 and side='ATTACKER' and participant_id in (v_part_a, v_part_b);
        v_ok := v_rows = 37 and v_rows3 = 25 and v_rows2 = 3;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T4 snapshot keeps every unit (rows=%s attackers=%s participants=%s)', v_rows, v_rows3, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T5 no ambiguous targeting: every ledger/shot target is a real participant-owned unit
        select count(*) into v_rows from public.combat_round_damage d
        where d.battle_id = v_battle and not exists (
            select 1 from public.combat_round_snapshot_units s
            where s.battle_id = d.battle_id and s.round_number = d.round_number
              and s.participant_id = d.target_participant_id and s.side = d.target_side
              and s.unit_type = d.target_unit_type and s.unit_id = d.target_unit_id
              and s.unit_number = d.target_unit_number);
        select count(*) into v_rows2 from public.combat_shots cs
        where cs.battle_id = v_battle and not exists (
            select 1 from public.combat_round_snapshot_units s
            where s.battle_id = cs.battle_id and s.round_number = cs.round_number
              and s.participant_id = cs.target_participant_id
              and s.unit_type = cs.target_unit_type and s.unit_id = cs.target_unit_id
              and s.unit_number = cs.target_unit_number);
        v_ok := v_rows = 0 and v_rows2 = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T5 every target resolves to its own participant unit (damage=%s shots=%s mismatches)',
                      v_rows, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T6 losses per participant
        select count(*), count(distinct participant_id) into v_rows, v_rows2
        from public.calculate_combat_ship_losses(v_battle) where side='ATTACKER' and unit_id='cruiser';
        v_ok := v_rows = 2 and v_rows2 = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T6 losses stay attributable per participant (%s rows / %s participants)', v_rows, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T7 defence losses remain a single defender participant
        select count(*), count(distinct participant_id) into v_rows, v_rows2
        from public.calculate_combat_defense_losses(v_battle) where side='DEFENDER';
        v_ok := v_rows >= 1 and v_rows2 = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T7 defence losses stay planet-scoped (%s rows / %s participant)', v_rows, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T8 no NULL participant in authoritative units
        select count(*) into v_rows from public.combat_individual_units where battle_id=v_battle and participant_id is null;
        v_ok := v_rows = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T8 no authoritative unit without participant_id (%s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- T9 the battle still resolves
        select cb.finished_at is not null,
               (case when cb.attacker_win then 1 else 0 end)
             + (case when cb.defender_win then 1 else 0 end)
             + (case when cb.draw then 1 else 0 end)
          into v_ok, v_rows
        from public.combat_battles cb where cb.id = v_battle;
        v_ok := v_ok and v_rows = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T9 a two-attacker battle still resolves (one result flag: %s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ============ SCENARIO 2 — deterministic target identity ============
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,started_at,arrives_at,status) values
          (v_fleet_a2, v_player, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED'),
          (v_fleet_b2, v_player, v_origin, v_target, 'ATTACK', clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_fleet_a2,'cruiser',1),(v_fleet_b2,'cruiser',1);

        insert into public.combat_battles(
          fleet_id,attacker_player_id,defender_planet_id,attacker_ships_before,attacker_ships_after,
          defender_ships_before,defender_ships_after,defender_defenses_before,defender_defenses_after,
          defender_combat_units_before,defender_combat_units_after,draw)
        values (v_fleet_a2,v_player,v_target,0,0,0,0,0,0,0,0,false) returning id into v_battle2;

        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_battle2,'ATTACKER','FLEET',v_fleet_a2,null,v_player,v_origin,'ATTACK'),
               (v_battle2,'ATTACKER','FLEET',v_fleet_b2,null,v_player,v_origin,'ATTACK'),
               (v_battle2,'DEFENDER','PLANET',null,v_target,v_def_player,null,null);

        select id into v_part_a2 from public.combat_battle_participants where battle_id=v_battle2 and side='ATTACKER' and fleet_id=v_fleet_a2;
        select id into v_part_b2 from public.combat_battle_participants where battle_id=v_battle2 and side='ATTACKER' and fleet_id=v_fleet_b2;
        select id into v_part_planet2 from public.combat_battle_participants where battle_id=v_battle2 and side='DEFENDER';

        perform public.initialize_individual_combat_units(v_battle2);
        perform public.create_combat_round_snapshot(v_battle2,1);

        insert into public.combat_shots(battle_id,round_number,shot_number,attacker_participant_id,target_participant_id,
          attacker_side,attacker_unit_type,attacker_unit_id,attacker_unit_number,target_unit_type,target_unit_id,target_unit_number,
          attack_value,target_shield_before,raw_damage,effective_damage,shield_damage,hull_damage,target_destroyed,
          rapidfire_value,rapidfire_triggered,rapidfire_probability,rapidfire_roll,is_initial_shot)
        values (v_battle2,1,1,v_part_planet2,v_part_a2,'DEFENDER','SHIP','small_cargo',1,'SHIP','cruiser',1, 5,0,0,0,0,0,false,1,false,0,1,true),
               (v_battle2,1,2,v_part_planet2,v_part_b2,'DEFENDER','SHIP','small_cargo',1,'SHIP','cruiser',1, 5,0,0,0,0,0,false,1,false,0,1,true);

        insert into public.combat_round_damage(battle_id,round_number,target_participant_id,target_side,target_unit_type,
          target_unit_id,target_unit_number,source_shot_number,attack_value,shield_damage,hull_damage,exploded)
        values (v_battle2,1,v_part_a2,'ATTACKER','SHIP','cruiser',1,1,5,0,0,false),
               (v_battle2,1,v_part_b2,'ATTACKER','SHIP','cruiser',1,2,5,0,0,false);

        select * into r from public.resolve_pending_target_damage(v_battle2,1,v_part_a2,'ATTACKER','SHIP','cruiser',1);
        v_ok := r.target_participant_id = v_part_a2 and r.shots_resolved = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T10 participant A resolves its own cruiser #1 (shots=%s)', r.shots_resolved) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        select * into r from public.resolve_pending_target_damage(v_battle2,1,v_part_b2,'ATTACKER','SHIP','cruiser',1);
        v_ok := r.target_participant_id = v_part_b2 and r.shots_resolved = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T11 participant B resolves its own cruiser #1 (shots=%s)', r.shots_resolved) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        select coalesce(sum(shield_damage),0) into v_rows from public.combat_round_damage
        where battle_id=v_battle2 and target_participant_id=v_part_a2 and target_unit_id='cruiser' and target_unit_number=1;
        select coalesce(sum(shield_damage),0) into v_rows2 from public.combat_round_damage
        where battle_id=v_battle2 and target_participant_id=v_part_b2 and target_unit_id='cruiser' and target_unit_number=1;
        v_ok := v_rows = 5 and v_rows2 = 5;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('T12 damage never crosses participants (A=%s B=%s)', v_rows, v_rows2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        begin
            select * into r from public.resolve_pending_target_damage(v_battle2,1,v_part_planet2,'ATTACKER','SHIP','cruiser',1);
        exception when others then v_raised := true;
        end;
        v_ok := v_raised;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'T13 a participant that owns no such unit is rejected' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        raise exception 'PHASE4A_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE4A_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_participant_identity_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT PARTICIPANT IDENTITY FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT PARTICIPANT IDENTITY FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_participant_identity_results order by orden;

drop table if exists t_combat_participant_identity_results;

rollback;
