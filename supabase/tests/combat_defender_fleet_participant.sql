-- ============================================================================
-- COMBAT ENGINE PHASE 4B — DEFENDER/FLEET PARTICIPANT REPRESENTATION
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Proves the Phase 4B invariants, all with the LIVE engine:
--
--   D1  a battle can own two DEFENDER/FLEET participants next to the planet
--   D2  each defending fleet's ships are materialised into ITS OWN participant
--   D3  the triple collision case: "planet cruiser #1", "defender fleet A
--       cruiser #1" and "defender fleet B cruiser #1" stay three distinct units
--   D4  each defending fleet is statted with ITS OWN owner technology context
--       (not the planet owner's, not another fleet's)
--   D5  defending-fleet ships are SHIP units, never DEFENCE
--   D6  the defence-repair loss reader cannot see fleet ships (planet-scoped repair)
--   D7  ship losses stay attributable per participant
--   D8  the round-1 snapshot keeps every unit with its participant (no silent drop)
--   D9  target identity is participant-scoped and a unit is never guessed
--   D10 with ZERO defending fleets the certified statement set is unchanged
--   D11 settlement FAILS CLOSED when a battle owns defending-fleet participants
--   D12 the fail-closed guard is inert on the certified single-fleet path
--   D13 debris stays battle-scoped: one generation, aggregating every participant
--   D14 one fleet can be a participant of a given battle only once
--
-- ROLLBACK SAFETY: every row created here (fleets, battles, participants, units,
-- snapshots, shots, damage, debris, repairs) lives inside a nested PL/pgSQL block
-- undone by a sentinel exception. No player, planet or resource is created.
-- ============================================================================

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_combat_defender_fleet_results;
create temp table t_combat_defender_fleet_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid;
    v_target uuid; v_def_player uuid; v_def_origin uuid;
    v_att_fleet uuid := gen_random_uuid();
    v_d1_fleet uuid := gen_random_uuid();
    v_d2_fleet uuid := gen_random_uuid();
    v_b1 uuid; v_b2 uuid; v_b4 uuid;
    v_f_guard uuid := gen_random_uuid();
    v_f_ok uuid := gen_random_uuid();
    v_f_d13 uuid := gen_random_uuid();
    v_f_unsup uuid := gen_random_uuid();
    v_hold timestamptz;
    v_b_guard uuid; v_res_battle uuid; v_status text;
    v_p_att uuid; v_p_planet uuid; v_p_d1 uuid; v_p_d2 uuid;
    v_h1 numeric; v_h2 numeric; v_exp numeric;
    v_n bigint; v_n2 bigint; v_n3 bigint; v_n4 bigint;
    v_ok boolean; v_fail integer := 0; v_lines text := ''; r record;
    v_raised boolean; v_msg text;
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
            raise exception 'PHASE4B_FIXTURE_ABORT: no HUMAN player with a usable planet';
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
            raise exception 'PHASE4B_FIXTURE_ABORT: no candidate defender planet';
        end if;

        select p3.id into v_def_origin
        from public.planets p3
        where p3.player_id = v_def_player and p3.universe_id = v_universe and p3.is_destroyed = false
        order by p3.id
        limit 1;

        if v_def_origin is null then
            v_def_origin := v_target;
        end if;

        -- deterministic defender composition: the planet owns the same ship type
        -- the two defending fleets field, so the collision case is exercised.
        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity)
        values (v_target, 'cruiser', 2), (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity)
        values (v_target, 'rocket_launcher', 2);

        -- ============ SCENARIO 1 — two defending fleets ====================
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status) values
          (v_att_fleet, v_player, v_origin, v_target, 'ATTACK',
           clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');

        -- D1 is owned by the HUMAN player (armour technology present),
        -- D2 is owned by the planet owner (no research) => different hull stats.
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status,holding_until) values
          (v_d1_fleet, v_player, v_origin, v_target, 'DEFEND',
           clock_timestamp()-interval '120 seconds', clock_timestamp()-interval '60 seconds', 'HOLDING',
           clock_timestamp()+interval '1 hour');

        -- `fleet_movements` carries a BEFORE INSERT ownership guard, so the second
        -- protecting player borrows the authenticated identity for that one insert
        -- and restores it immediately (players has no write trigger, and the whole
        -- fixture block is rolled back).
        update public.players set user_id = null where id = v_player;
        update public.players set user_id = v_user where id = v_def_player;

        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status,holding_until) values
          (v_d2_fleet, v_def_player, v_def_origin, v_target, 'DEFEND',
           clock_timestamp()-interval '120 seconds', clock_timestamp()-interval '60 seconds', 'HOLDING',
           clock_timestamp()+interval '1 hour');

        update public.players set user_id = null where id = v_def_player;
        update public.players set user_id = v_user where id = v_player;

        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values
          (v_att_fleet,'cruiser',5), (v_d1_fleet,'cruiser',3), (v_d2_fleet,'cruiser',4);

        insert into public.combat_battles(
          fleet_id,attacker_player_id,defender_planet_id,draw)
        values (v_att_fleet,v_player,v_target,false) returning id into v_b1;

        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_b1,'ATTACKER','FLEET',v_att_fleet,null,v_player,v_origin,'ATTACK'),
               (v_b1,'DEFENDER','PLANET',null,v_target,v_def_player,null,null),
               (v_b1,'DEFENDER','FLEET',v_d1_fleet,null,v_player,v_origin,'DEFEND'),
               (v_b1,'DEFENDER','FLEET',v_d2_fleet,null,v_def_player,v_def_origin,'DEFEND');

        select id into v_p_att    from public.combat_battle_participants where battle_id=v_b1 and side='ATTACKER' and fleet_id=v_att_fleet;
        select id into v_p_planet from public.combat_battle_participants where battle_id=v_b1 and side='DEFENDER' and participant_type='PLANET';
        select id into v_p_d1     from public.combat_battle_participants where battle_id=v_b1 and side='DEFENDER' and fleet_id=v_d1_fleet;
        select id into v_p_d2     from public.combat_battle_participants where battle_id=v_b1 and side='DEFENDER' and fleet_id=v_d2_fleet;

        perform public.initialize_individual_combat_units(v_b1);

        -- ---- D1: the battle owns two defending fleets ---------------------
        select count(*),
               count(*) filter (where side='ATTACKER' and participant_type='FLEET'),
               count(*) filter (where side='DEFENDER' and participant_type='PLANET'),
               count(*) filter (where side='DEFENDER' and participant_type='FLEET')
          into v_n, v_n2, v_n3, v_n4
        from public.combat_battle_participants where battle_id=v_b1;

        v_ok := v_n=4 and v_n2=1 and v_n3=1 and v_n4=2
                and v_p_att is not null and v_p_planet is not null and v_p_d1 is not null and v_p_d2 is not null;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D1 battle owns 1 attacker + 1 planet + 2 defending fleets (%s participants)', v_n) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D2: per-participant unit materialisation ---------------------
        select count(*) filter (where participant_id=v_p_planet),
               count(*) filter (where participant_id=v_p_d1),
               count(*) filter (where participant_id=v_p_d2),
               count(*) filter (where participant_id is null)
          into v_n, v_n2, v_n3, v_n4
        from public.combat_individual_units where battle_id=v_b1 and round_number=1;

        v_ok := v_n=14 and v_n2=3 and v_n3=4 and v_n4=0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D2 units per participant (planet=%s D1=%s D2=%s null=%s)', v_n, v_n2, v_n3, v_n4) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D3: the triple collision case --------------------------------
        select count(*), count(distinct participant_id) into v_n, v_n2
        from public.combat_individual_units
        where battle_id=v_b1 and round_number=1 and side='DEFENDER'
          and unit_type='SHIP' and unit_id='cruiser' and unit_number=1;

        v_ok := v_n=3 and v_n2=3;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D3 three distinct "cruiser #1" units survive (%s rows / %s participants)', v_n, v_n2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D4: each defending fleet uses its OWN owner tech context -----
        select max(hull_max) into v_h1 from public.combat_individual_units
        where battle_id=v_b1 and round_number=1 and participant_id=v_p_d1 and unit_id='cruiser';
        select max(hull_max) into v_h2 from public.combat_individual_units
        where battle_id=v_b1 and round_number=1 and participant_id=v_p_d2 and unit_id='cruiser';

        v_ok := v_h1 = public.get_combat_ship_hull(v_player,'cruiser')
                and v_h2 = public.get_combat_ship_hull(v_def_player,'cruiser')
                and v_h1 <> v_h2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D4 each defending fleet keeps its owner context (D1 hull=%s vs D2 hull=%s)', v_h1, v_h2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D5: defending-fleet units are SHIP units, never DEFENCE -------
        select count(*) into v_n from public.combat_individual_units
        where battle_id=v_b1 and round_number=1
          and participant_id in (v_p_d1,v_p_d2) and unit_type <> 'SHIP';

        v_ok := v_n = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D5 defending-fleet units are never DEFENCE (%s offending rows)', v_n) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D6: repair stays planet-scoped --------------------------------
        select count(*) into v_n from public.calculate_combat_defense_losses(v_b1)
        where participant_id in (v_p_d1,v_p_d2);

        v_ok := v_n = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D6 the repair loss reader cannot see fleet ships (%s rows)', v_n) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D7: ship losses stay attributable per participant -------------
        select count(*), count(distinct participant_id) into v_n, v_n2
        from public.calculate_combat_ship_losses(v_b1);

        v_ok := v_n = 5 and v_n2 = 4;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D7 ship losses are per-participant (%s rows / %s participants)', v_n, v_n2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D8: the snapshot keeps every unit, none without participant ---
        perform public.create_combat_round_snapshot(v_b1,1);

        select count(*),
               count(*) filter (where participant_id is null),
               count(*) filter (where participant_id=v_p_d1),
               count(*) filter (where participant_id=v_p_d2)
          into v_n, v_n2, v_n3, v_n4
        from public.combat_round_snapshot_units where battle_id=v_b1 and round_number=1;

        v_ok := v_n = 26 and v_n2 = 0 and v_n3 = 3 and v_n4 = 4;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D8 snapshot keeps all 26 units (D1=%s D2=%s null=%s)', v_n3, v_n4, v_n2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ---- D9: target identity is participant-scoped ---------------------
        insert into public.combat_shots(battle_id,round_number,shot_number,attacker_participant_id,target_participant_id,
          attacker_side,attacker_unit_type,attacker_unit_id,attacker_unit_number,target_unit_type,target_unit_id,target_unit_number,
          attack_value,target_shield_before,raw_damage,effective_damage,shield_damage,hull_damage,target_destroyed,
          rapidfire_value,rapidfire_triggered,rapidfire_probability,rapidfire_roll,is_initial_shot)
        values (v_b1,1,1,v_p_att,v_p_d1,'ATTACKER','SHIP','cruiser',1,'SHIP','cruiser',1, 5,0,0,0,0,0,false,1,false,0,1,true),
               (v_b1,1,2,v_p_att,v_p_d2,'ATTACKER','SHIP','cruiser',1,'SHIP','cruiser',1, 5,0,0,0,0,0,false,1,false,0,1,true);

        insert into public.combat_round_damage(battle_id,round_number,target_participant_id,target_side,target_unit_type,
          target_unit_id,target_unit_number,source_shot_number,attack_value,shield_damage,hull_damage,exploded)
        values (v_b1,1,v_p_d1,'DEFENDER','SHIP','cruiser',1,1,5,0,0,false),
               (v_b1,1,v_p_d2,'DEFENDER','SHIP','cruiser',1,2,5,0,0,false);

        select * into r from public.resolve_pending_target_damage(v_b1,1,v_p_d1,'DEFENDER','SHIP','cruiser',1);
        v_ok := r.target_participant_id = v_p_d1 and r.shots_resolved = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D9a defending fleet A resolves its own cruiser #1 (shots=%s)', r.shots_resolved) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        select * into r from public.resolve_pending_target_damage(v_b1,1,v_p_d2,'DEFENDER','SHIP','cruiser',1);
        v_ok := r.target_participant_id = v_p_d2 and r.shots_resolved = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D9b defending fleet B resolves its own cruiser #1 (shots=%s)', r.shots_resolved) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        begin
            select * into r from public.resolve_pending_target_damage(v_b1,1,v_p_planet,'DEFENDER','SHIP','destroyer',1);
        exception when others then v_raised := true;
        end;
        v_ok := v_raised;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'D9c a participant that owns no such unit is rejected, never guessed' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ==== D10: with ZERO defending fleets the certified set is unchanged ====
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status) values
          (v_f_ok, v_player, v_origin, v_target, 'ATTACK',
           clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_f_ok,'cruiser',5);

        insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
        values (v_f_ok,v_player,v_target,false) returning id into v_b2;
        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_b2,'ATTACKER','FLEET',v_f_ok,null,v_player,v_origin,'ATTACK'),
               (v_b2,'DEFENDER','PLANET',null,v_target,v_def_player,null,null);

        perform public.initialize_individual_combat_units(v_b2);

        select count(*) into v_n from public.combat_individual_units where battle_id=v_b2 and round_number=1;
        select count(*) into v_n2 from public.combat_battle_participants
        where battle_id=v_b2 and side='DEFENDER' and participant_type='FLEET';

        -- 5 attacker cruisers + (2 cruiser + 10 small_cargo + 2 rocket_launcher)
        v_ok := v_n = 19 and v_n2 = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D10 zero defending fleets => certified unit set unchanged (%s units, %s fleet defenders)', v_n, v_n2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ==== D11: settlement FAILS CLOSED on defending-fleet participants ====
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status) values
          (v_f_guard, v_player, v_origin, v_target, 'ATTACK',
           clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_f_guard,'cruiser',2);

        insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
        values (v_f_guard,v_player,v_target,false) returning id into v_b_guard;
        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_b_guard,'ATTACKER','FLEET',v_f_guard,null,v_player,v_origin,'ATTACK'),
               (v_b_guard,'DEFENDER','PLANET',null,v_target,v_def_player,null,null),
               (v_b_guard,'DEFENDER','FLEET',v_d1_fleet,null,v_player,v_origin,'DEFEND');

        -- PHASE ACS (2026-09-22): a battle owning DEFENDER/FLEET participants is now
        -- SETTLED (PG-08 + PG-17) instead of refused: the defending fleet's survivors are
        -- rewritten and its hold is preserved. The fail-closed guarantee is kept for
        -- participant shapes the settlement cannot attribute (see D11b).
        perform public.initialize_individual_combat_units(v_b_guard);

        v_raised := false; v_msg := null;
        begin
            perform public.resolve_attack_arrival(v_f_guard);
        exception when others then v_raised := true; v_msg := sqlerrm;
        end;

        select fm.status, fm.holding_until into v_status, v_hold
          from public.fleet_movements fm where fm.id = v_d1_fleet;
        select count(*) into v_n from public.fleet_movement_ships s where s.fleet_id = v_d1_fleet;
        select coalesce(sum(s.quantity),0) into v_n2 from public.fleet_movement_ships s where s.fleet_id = v_d1_fleet;

        v_ok := not v_raised and v_status = 'HOLDING' and v_hold > clock_timestamp() and v_n <= 1 and v_n2 <= 3;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D11a a battle owning defending fleets now settles and the hold survives (status=%s rows=%s ships=%s)',
                      v_status, v_n, v_n2) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- D11b: an unhandled participant shape must still refuse to settle
        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status) values
          (v_f_unsup, v_player, v_origin, v_target, 'ATTACK',
           clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_f_unsup,'cruiser',2);

        insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
        values (v_f_unsup,v_player,v_target,false) returning id into v_b_guard;
        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_b_guard,'ATTACKER','FLEET',v_f_unsup,null,v_player,v_origin,'ATTACK'),
               (v_b_guard,'DEFENDER','PLANET',null,v_target,v_def_player,null,null),
               (v_b_guard,'DEFENDER','ENEMY',null,null,null,null,null);

        v_raised := false; v_msg := null;
        begin
            perform public.resolve_attack_arrival(v_f_unsup);
        exception when others then v_raised := true; v_msg := sqlerrm;
        end;
        v_ok := v_raised and v_msg like '%BATTLE_SETTLEMENT_UNSUPPORTED_PARTICIPANT%';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D11b settlement still FAILS CLOSED on an unhandled participant shape (%s)', left(coalesce(v_msg,'no error'),80)) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ==== D12: the guard is inert on the certified single-fleet path ======
        -- D11a settled a battle on this planet, so its resource clock is advanced; make the
        -- fixture clock consistent again for the next arrival (rolled back with the fixture).
        update public.planet_resources
           set last_calculated_at = now() - interval '1 hour', updated_at = now()
         where planet_id = v_target;

        v_res_battle := public.resolve_attack_arrival(v_f_ok);
        select status into v_status from public.fleet_movements where id = v_f_ok;

        v_ok := v_res_battle is not null and v_res_battle = v_b2 and v_status = 'RETURNING';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D12 the certified single-fleet attack still settles (status=%s)', v_status) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ==== D13: debris stays battle-scoped and participant-independent ====
        -- D12 settled a real battle on this planet, so restore a deterministic
        -- defender composition before the debris proof.
        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity)
        values (v_target, 'cruiser', 2), (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity)
        values (v_target, 'rocket_launcher', 2);

        insert into public.fleet_movements(id,player_id,origin_planet_id,destination_planet_id,mission_type,
            started_at,arrives_at,status) values
          (v_f_d13, v_player, v_origin, v_target, 'ATTACK',
           clock_timestamp()-interval '60 seconds', clock_timestamp()-interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity) values (v_f_d13,'cruiser',5);

        insert into public.combat_battles(fleet_id,attacker_player_id,defender_planet_id,draw)
        values (v_f_d13,v_player,v_target,false) returning id into v_b4;
        insert into public.combat_battle_participants(battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
        values (v_b4,'ATTACKER','FLEET',v_f_d13,null,v_player,v_origin,'ATTACK'),
               (v_b4,'DEFENDER','PLANET',null,v_target,v_def_player,null,null),
               (v_b4,'DEFENDER','FLEET',v_d2_fleet,null,v_def_player,v_def_origin,'DEFEND');

        perform public.initialize_individual_combat_units(v_b4);
        select id into v_p_d2 from public.combat_battle_participants where battle_id=v_b4 and side='DEFENDER' and fleet_id=v_d2_fleet;

        -- deterministic losses: the defending fleet and the planet's ships die
        update public.combat_individual_units set alive=false
        where battle_id=v_b4 and round_number=1 and participant_id=v_p_d2;
        update public.combat_individual_units set alive=false
        where battle_id=v_b4 and round_number=1 and unit_type='SHIP'
          and participant_id=(select id from public.combat_battle_participants
                              where battle_id=v_b4 and side='DEFENDER' and participant_type='PLANET');

        select count(*), count(distinct participant_id) into v_n, v_n2
        from public.calculate_combat_ship_losses(v_b4) where destroyed_quantity > 0;

        select * into r from public.create_combat_debris(v_b4);
        select count(*) into v_n3 from public.combat_debris_generations where battle_id=v_b4;
        v_exp := (select coalesce(sum(debris_metal),0) from public.calculate_combat_ship_debris(v_b4));

        v_ok := v_n = 3 and v_n2 = 2 and v_n3 = 1
                and r.out_already_generated = false and r.out_debris_metal = v_exp and v_exp > 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('D13 one battle-level debris generation merging %s participants (metal=%s)', v_n2, r.out_debris_metal) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        -- ==== D14: one fleet can be a participant of a battle only once =====
        begin
            insert into public.combat_battle_participants(
              battle_id,side,participant_type,fleet_id,planet_id,player_id,origin_planet_id,mission_type)
            values (v_b1,'DEFENDER','FLEET',v_d1_fleet,null,v_player,v_origin,'DEFEND');
        exception when unique_violation then v_raised := true;
        end;
        v_ok := v_raised;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'D14 a fleet cannot join the same battle twice' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        raise exception 'PHASE4B_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE4B_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_defender_fleet_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT DEFENDER FLEET PARTICIPANT FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT DEFENDER FLEET PARTICIPANT FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_defender_fleet_results order by orden;

drop table if exists t_combat_defender_fleet_results;

rollback;
