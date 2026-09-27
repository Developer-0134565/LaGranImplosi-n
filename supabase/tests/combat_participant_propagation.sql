-- ============================================================================
-- COMBAT ENGINE PHASE 1 — PRODUCTION-PATH COMBAT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Rewritten in Phase 1 (2026-09-21). The previous version hardcoded players and
-- planets that no longer exist in LIVE (60f1043a-…, c0d77158-…, bbbbbbbb-…,
-- aaaaaaaa-…), so every INSERT failed on its foreign key before asserting
-- anything. This version resolves a VALID fixture from LIVE at run time, using
-- the same selector as shipyard_defense_lifecycle.sql.
--
-- ROLLBACK SAFETY: the fixture + battle run inside a nested PL/pgSQL block whose
-- changes are undone by a sentinel exception before the block exits, so this can
-- be executed in ANY client (psql, SQL editor, automation) without leaving
-- production rows behind. The file-level begin/rollback only wraps the report
-- temp table.
--
-- Exercises the REAL production path only:
--   fleet (ATTACK, ARRIVED) → resolve_attack_arrival → battle → participants
--   → individual units → round snapshot → shots → damage ledger → losses
--   → loot → defense repair → debris → RETURNING, then a replay check.
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


drop table if exists t_combat_phase1_results;
create temp table t_combat_phase1_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid;
    v_target uuid; v_def_player uuid;
    v_galaxy integer; v_system integer; v_position integer;
    v_fleet uuid := gen_random_uuid();
    v_battle uuid; v_battle_replay uuid;
    v_att uuid; v_defp uuid;
    v_att_units bigint; v_def_units bigint; v_null_participants bigint;
    v_snap_rows bigint; v_dmg_rows bigint; v_dmg_total numeric;
    v_finished boolean; v_flags integer; v_attacker_win boolean;
    v_def_ship_destroyed bigint; v_def_defense_destroyed bigint;
    v_att_alive bigint; v_att_destroyed bigint;
    v_fleet_ships bigint; v_fleet_ships_replay bigint;
    v_gen integer; v_debris_metal numeric; v_repairs integer;
    v_repaired bigint; v_pd_qty bigint;
    v_loot_applied timestamptz; v_loot_metal numeric;
    v_rounds_before integer;
    v_status_before text; v_status_after text;
    v_ok boolean; v_fail integer := 0; v_lines text := '';
begin
    begin
        /* ---- LIVE-resolved attacker: a HUMAN player with a real planet ---- */
        select pl.id, pl.user_id, p.id, p.universe_id
          into v_player, v_user, v_origin, v_universe
        from public.planets p
        join public.players pl on pl.id = p.player_id
        where pl.player_type = 'HUMAN' and pl.user_id is not null and p.is_destroyed = false
        order by (pl.username like 'DevPlayer%'), p.created_at, p.id
        limit 1;

        if v_origin is null then
            raise exception 'PHASE1_FIXTURE_ABORT: no HUMAN player with a usable planet';
        end if;

        /* The fleet_movements write trigger (enforce_player_write_access) requires
           an authenticated identity, exactly like the real client/worker session.
           Same convention as shipyard_defense_lifecycle.sql / research_lifecycle.sql. */
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        /* ---- LIVE-resolved target: another real planet, same universe ---- */
        select p2.id, p2.player_id, p2.galaxy, p2.system, p2.position
          into v_target, v_def_player, v_galaxy, v_system, v_position
        from public.planets p2
        where p2.universe_id = v_universe and p2.is_destroyed = false
          and p2.player_id <> v_player and p2.id <> v_origin
        order by p2.galaxy, p2.system, p2.position, p2.id
        limit 1;

        if v_target is null then
            raise exception 'PHASE1_FIXTURE_ABORT: no candidate defender planet';
        end if;

        /* ---- deterministic defender composition ---- */
        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

        /* ---- attacking fleet: 20 cruisers, already ARRIVED ---- */
        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (
            v_fleet, v_player, v_origin, v_target, 'ATTACK',
            clock_timestamp() - interval '60 seconds',
            clock_timestamp() - interval '1 second',
            'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_fleet, 'cruiser', 20);

        select fm.status into v_status_before from public.fleet_movements fm where fm.id = v_fleet;

        /* =================== REAL PRODUCTION ENTRY POINT =================== */
        v_battle := public.resolve_attack_arrival(v_fleet);


        /* ---- 01 battle created for the attacking fleet ---- */
        v_ok := v_battle is not null and exists (
            select 1 from public.combat_battles cb
            where cb.id = v_battle and cb.fleet_id = v_fleet
              and cb.attacker_player_id = v_player and cb.defender_planet_id = v_target)
            and v_status_before = 'ARRIVED';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || '01 one battle created; fleet_id, attacker and defender planet correct (fleet was ARRIVED)' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 02 participants ---- */
        select id into v_att from public.combat_battle_participants
        where battle_id = v_battle and side = 'ATTACKER' and participant_type = 'FLEET'
          and fleet_id = v_fleet and player_id = v_player and origin_planet_id = v_origin;

        select id into v_defp from public.combat_battle_participants
        where battle_id = v_battle and side = 'DEFENDER' and participant_type = 'PLANET'
          and planet_id = v_target and player_id = v_def_player;

        v_ok := v_att is not null and v_defp is not null
            and (select count(*) from public.combat_battle_participants where battle_id = v_battle) = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || '02 exactly two participants with correct ownership (ATTACKER/FLEET + DEFENDER/PLANET)' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 03 individual units: identity, ownership and composition ---- */
        select count(*) filter (where ciu.side = 'ATTACKER' and ciu.participant_id = v_att),
               count(*) filter (where ciu.side = 'DEFENDER' and ciu.participant_id = v_defp),
               count(*) filter (where ciu.participant_id is null)
          into v_att_units, v_def_units, v_null_participants
        from public.combat_individual_units ciu
        where ciu.battle_id = v_battle and ciu.round_number = 1;

        v_ok := v_att_units = 20 and v_def_units = 12 and v_null_participants = 0
            and (select count(*) from public.combat_individual_units
                 where battle_id = v_battle and round_number = 1
                   and side = 'DEFENDER' and unit_type = 'DEFENSE') = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('03 units attributed correctly (attacker=%s defender=%s null_participant=%s)',
                      v_att_units, v_def_units, v_null_participants) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 04 round snapshot belongs to the battle ---- */
        select count(*), count(*) filter (where participant_id is null)
          into v_snap_rows, v_null_participants
        from public.combat_round_snapshot_units
        where battle_id = v_battle and round_number = 1;

        v_ok := v_snap_rows > 0 and v_null_participants = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('04 round snapshot belongs to the battle (%s rows, %s without participant)',
                      v_snap_rows, v_null_participants) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 05 damage ledger resolves real damage ---- */
        select count(*), count(*) filter (where target_participant_id is null),
               coalesce(sum(shield_damage + hull_damage), 0)
          into v_dmg_rows, v_null_participants, v_dmg_total
        from public.combat_round_damage
        where battle_id = v_battle;

        v_ok := v_dmg_rows > 0 and v_null_participants = 0 and v_dmg_total > 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('05 damage ledger belongs to the battle (%s rows, total damage %s)',
                      v_dmg_rows, v_dmg_total) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 06 result persisted ---- */
        select cb.finished_at is not null,
               (case when cb.attacker_win then 1 else 0 end)
             + (case when cb.defender_win then 1 else 0 end)
             + (case when cb.draw then 1 else 0 end),
               coalesce(cb.attacker_win, false)
          into v_finished, v_flags, v_attacker_win
        from public.combat_battles cb where cb.id = v_battle;

        v_ok := v_finished and v_flags = 1 and v_attacker_win;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('06 battle finished with exactly one result flag; attacker_win=%s', v_attacker_win) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 07 losses are derived from the ledger ---- */
        select coalesce(sum(destroyed_quantity), 0) into v_def_ship_destroyed
        from public.calculate_combat_ship_losses(v_battle)
        where side = 'DEFENDER' and unit_id = 'small_cargo';

        select coalesce(sum(destroyed_quantity), 0) into v_def_defense_destroyed
        from public.calculate_combat_defense_losses(v_battle)
        where side = 'DEFENDER' and unit_id = 'rocket_launcher';

        select count(*) into v_att_alive
        from public.combat_individual_units
        where battle_id = v_battle
          and round_number = (select max(round_number) from public.combat_individual_units where battle_id = v_battle)
          and side = 'ATTACKER' and alive;

        v_att_destroyed := 20 - v_att_alive;

        v_ok := v_def_ship_destroyed = 10 and v_def_defense_destroyed = 2
            and v_att_destroyed >= 0 and v_att_destroyed <= 2 and v_att_alive >= 18;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('07 losses derived correctly (defender ships %s/10, defenses %s/2, attacker losses %s)',
                      v_def_ship_destroyed, v_def_defense_destroyed, v_att_destroyed) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 08 survivors persisted to the authoritative tables ---- */
        select coalesce(sum(quantity), 0) into v_fleet_ships
        from public.fleet_movement_ships where fleet_id = v_fleet;

        v_ok := v_fleet_ships = v_att_alive
            and coalesce((select sum(quantity) from public.planet_ships
                          where planet_id = v_target and ship_id = 'small_cargo'), 0) = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('08 survivors match the last round (attacker fleet ships %s of 20, defender ships left %s)',
                      v_fleet_ships,
                      coalesce((select sum(quantity) from public.planet_ships
                                where planet_id = v_target and ship_id = 'small_cargo'), 0)) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 09 debris generated exactly once and consistent with losses ---- */
        select count(*), coalesce(max(metal_generated), 0)
          into v_gen, v_debris_metal
        from public.combat_debris_generations where battle_id = v_battle;

        v_ok := v_gen = 1 and v_debris_metal > 0
            and abs(v_debris_metal
                    - 0.30 * (select coalesce(sum(metal_lost), 0)
                              from public.calculate_combat_ship_losses(v_battle))) < 0.01
            and exists (select 1 from public.debris_fields df
                        where df.universe_id = v_universe and df.galaxy = v_galaxy
                          and df.system = v_system and df.position = v_position
                          and df.metal >= v_debris_metal);
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('09 debris generated once (%s row(s), metal %s) and credited to the target coordinate',
                      v_gen, v_debris_metal) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 10 loot applied once, only for an attacker win ---- */
        select cb.loot_applied_at, cb.loot_metal into v_loot_applied, v_loot_metal
        from public.combat_battles cb where cb.id = v_battle;

        v_ok := v_loot_applied is not null and v_loot_metal >= 0
            and (select cb2.loot_crystal >= 0 and cb2.loot_deuterium >= 0
                 from public.combat_battles cb2 where cb2.id = v_battle);
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('10 loot applied exactly once (applied_at=%s, metal %s)', v_loot_applied, v_loot_metal) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 11 defense repair recorded and applied to planet_defenses ---- */
        select count(*), coalesce(max(repaired_quantity), -1) into v_repairs, v_repaired
        from public.combat_defense_repairs
        where battle_id = v_battle and defense_id = 'rocket_launcher';

        select coalesce(sum(quantity), 0) into v_pd_qty
        from public.planet_defenses where planet_id = v_target and defense_id = 'rocket_launcher';

        v_ok := v_repairs = 1 and v_repaired between 0 and 2 and v_pd_qty = v_repaired;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('11 defense repair recorded once (repaired %s of 2, planet_defenses now %s)',
                      v_repaired, v_pd_qty) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- 12 replay of the same arrival is idempotent ---- */
        select count(*) into v_rounds_before from public.combat_rounds where battle_id = v_battle;

        v_battle_replay := public.resolve_attack_arrival(v_fleet);

        select coalesce(sum(quantity), 0) into v_fleet_ships_replay
        from public.fleet_movement_ships where fleet_id = v_fleet;

        select fm.status into v_status_after from public.fleet_movements fm where fm.id = v_fleet;

        v_ok := v_battle_replay = v_battle
            and (select count(*) from public.combat_battles where fleet_id = v_fleet) = 1
            and (select count(*) from public.combat_debris_generations where battle_id = v_battle) = 1
            and (select count(*) from public.combat_defense_repairs where battle_id = v_battle) = 1
            and (select count(*) from public.combat_rounds where battle_id = v_battle) = v_rounds_before
            and v_fleet_ships_replay = v_fleet_ships
            and v_status_after = 'RETURNING';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('12 replay is idempotent (same battle=%s, no second battle/debris/repair, fleet %s)',
                      v_battle_replay = v_battle, v_status_after) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- end of fixture: undo every change made by this block ---- */
        raise exception 'PHASE1_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE1_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_phase1_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT PHASE 1 FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT PHASE 1 FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_phase1_results order by orden;

drop table if exists t_combat_phase1_results;

rollback;
