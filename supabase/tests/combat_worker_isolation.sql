-- ============================================================================
-- COMBAT ENGINE PHASE 2 — CB-04 WORKER ERROR-ISOLATION FIXTURE
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Proves that one malformed fleet can no longer poison the whole fleet batch,
-- while every fleet stays individually atomic:
--
--   fleet A = ATTACK with no ships (resolve_combat raises)  -> processed FIRST
--   fleet B = valid ATTACK combat                          -> same invocation
--
--   W1  the invocation returns only the successful fleet
--   W2  the failing fleet produced NO battle
--   W3  the valid fleet's battle exists, is finished and was won
--   W4  the failing fleet is unchanged (still OUTBOUND, no return schedule) and
--       therefore retryable by the next tick — it was NOT partially committed
--   W5  the valid fleet advanced to RETURNING
--   W6  the valid battle is complete and atomic (participants, units, rounds,
--       exactly one debris generation)
--   W7  retrying does not duplicate anything and does not disturb the other fleet
--   W8  the per-fleet exception handlers exist (three loops: OUTBOUND, HOLDING,
--       RETURNING) and failures are therefore observable through
--       FLEET_RESOLUTION_FAILED warnings in the Postgres log
--
-- ROLLBACK SAFETY: all fleets, battles and state changes live inside a nested
-- PL/pgSQL block undone by a sentinel exception, so no poisoned fleet and no
-- combat residue is ever left in LIVE.
-- ============================================================================

begin;

drop table if exists t_combat_worker_results;
create temp table t_combat_worker_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid; v_target uuid;
    v_bad_fleet uuid := gen_random_uuid();
    v_good_fleet uuid := gen_random_uuid();
    v_bad_battle uuid; v_good_battle uuid;
    v_rows bigint; v_rows2 bigint;
    v_status_bad text; v_status_good text; v_returns_bad timestamp with time zone;
    v_finished boolean; v_attacker_win boolean;
    v_parts bigint; v_units bigint; v_rounds bigint; v_gen bigint;
    v_handlers integer;
    v_ok boolean; v_fail integer := 0; v_lines text := '';
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
            raise exception 'PHASE2_FIXTURE_ABORT: no HUMAN player with a usable planet';
        end if;

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        select p2.id into v_target
        from public.planets p2
        where p2.universe_id = v_universe and p2.is_destroyed = false
          and p2.player_id <> v_player and p2.id <> v_origin
        order by p2.galaxy, p2.system, p2.position, p2.id
        limit 1;

        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

        /* fleet A: invalid ATTACK (no ships at all), arrives first */
        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_bad_fleet, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '120 seconds',
                clock_timestamp() - interval '2 seconds', 'OUTBOUND');

        /* fleet B: valid ATTACK, same invocation, arrives second */
        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_good_fleet, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '120 seconds',
                clock_timestamp() - interval '1 second', 'OUTBOUND');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_good_fleet, 'cruiser', 20);

        /* ---- W1: the failing fleet does not abort the batch --------------- */
        select count(*) into v_rows from public.process_fleet_movements();

        v_ok := v_rows = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W1 invocation completed and returned %s row(s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W2: the failing fleet produced no battle --------------------- */
        select id into v_bad_battle from public.combat_battles where fleet_id = v_bad_fleet;

        v_ok := v_bad_battle is null;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'W2 the invalid fleet created no battle' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W3: the valid fleet was resolved in the same invocation ------- */
        select cb.id, cb.finished_at is not null, coalesce(cb.attacker_win, false)
          into v_good_battle, v_finished, v_attacker_win
        from public.combat_battles cb where cb.fleet_id = v_good_fleet;

        v_ok := v_good_battle is not null and v_finished and v_attacker_win;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W3 the valid fleet resolved in the same invocation (battle=%s finished=%s win=%s)',
                      v_good_battle is not null, v_finished, v_attacker_win) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W4: the failing fleet is untouched (atomic rollback) ---------- */
        select fm.status, fm.returns_at into v_status_bad, v_returns_bad
        from public.fleet_movements fm where fm.id = v_bad_fleet;

        v_ok := v_status_bad = 'OUTBOUND' and v_returns_bad is null;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W4 the failing fleet stayed %s with returns_at=%s (retryable, no partial commit)',
                      v_status_bad, v_returns_bad) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W5: the valid fleet advanced --------------------------------- */
        select fm.status into v_status_good from public.fleet_movements fm where fm.id = v_good_fleet;

        v_ok := v_status_good = 'RETURNING';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W5 the valid fleet advanced to %s', v_status_good) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W6: the valid battle is complete and atomic ------------------- */
        select (select count(*) from public.combat_battle_participants where battle_id = v_good_battle),
               (select count(*) from public.combat_individual_units where battle_id = v_good_battle),
               (select count(*) from public.combat_rounds where battle_id = v_good_battle),
               (select count(*) from public.combat_debris_generations where battle_id = v_good_battle)
          into v_parts, v_units, v_rounds, v_gen;

        v_ok := v_parts = 2 and v_units = 32 and v_rounds >= 1 and v_gen = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W6 valid battle complete (participants=%s units=%s rounds=%s debris=%s)',
                      v_parts, v_units, v_rounds, v_gen) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W7: retry is safe and does not duplicate anything ------------- */
        select count(*) into v_rows2 from public.process_fleet_movements();
        select fm.status into v_status_bad from public.fleet_movements fm where fm.id = v_bad_fleet;
        select fm.status into v_status_good from public.fleet_movements fm where fm.id = v_good_fleet;

        v_ok := v_rows2 = 0 and v_status_bad = 'OUTBOUND' and v_status_good = 'RETURNING'
                and (select count(*) from public.combat_battles where fleet_id = v_good_fleet) = 1
                and (select count(*) from public.combat_battles where fleet_id = v_bad_fleet) = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W7 retry is safe (rows=%s bad=%s good=%s)', v_rows2, v_status_bad, v_status_good) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- W8: per-fleet handlers exist (observability) ------------------ */
        select (length(prosrc) - length(replace(prosrc, 'FLEET_RESOLUTION_FAILED', '')))
               / length('FLEET_RESOLUTION_FAILED')
          into v_handlers
        from pg_proc
        where pronamespace = 'public'::regnamespace and proname = 'process_fleet_movements';

        v_ok := v_handlers = 3;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('W8 per-fleet exception handlers present and observable (%s loops)', v_handlers) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        raise exception 'PHASE2_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE2_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_worker_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT WORKER ISOLATION FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT WORKER ISOLATION FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_worker_results order by orden;

drop table if exists t_combat_worker_results;

rollback;
