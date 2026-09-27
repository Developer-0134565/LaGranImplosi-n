-- FLEET ENGINE — HELPER ACL + HOLDING CARGO FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migrations 20260925211615_tighten_fleet_calculation_helper_acl and
-- 20260925211804_tighten_fleet_distance_helper_acl):
--   * the two canonical calculation helpers `calculate_fleet_distance` and `calculate_fleet_travel_time`
--     are internal: no PUBLIC/anon/authenticated EXECUTE, service_role only;
--   * the rest of the canonical cluster stays equally closed (regression guard) while the four
--     dispatchers remain reachable by `authenticated` (no over-closing);
--   * the internal path still evaluates (the owner context is unaffected by the revoke);
--   * cargo integration: a TRANSPORT delivers its cargo ONCE (the arrival zeroes the movement cargo,
--     so the generic RETURNING settlement cannot credit the origin a second time);
--   * cargo integration: an ACS_HOLD fleet keeps its cargo through OUTBOUND -> HOLDING -> RETURNING and
--     the cargo lands on the ORIGIN exactly once at COMPLETED, never on the supported planet;
--   * structural guards (2026-09-25 transversal audit): a single travel-time implementation, no
--     dispatcher reading `ship_definitions.speed`, and the legacy `fleet_speed` column readable only by
--     the informational `calculate_universe_rates` snapshot.
--
-- Boundary: dispatch/authorization/lifecycle of ACS_HOLD is already certified by
-- `fleet_acs_hold_lifecycle.sql`, `fleet_support_authorization_chain.sql` and `fleet_speed_classes.sql`;
-- this fixture does not repeat it — it starts from a fixture movement and drives the real worker.
--
-- LIMITATION: single-session harness. True concurrency is not executed; determinism is obtained by
-- pinning `planet_resources.last_calculated_at` to the settlement instant (zero elapsed production).

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_fleet_matrix_results;
create temp table t_fleet_matrix_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_user_a uuid; v_player_a uuid; v_planet_a uuid; v_universe_a uuid;
    v_player_b uuid; v_planet_b uuid;
    v_fleet_t uuid; v_fleet_h uuid;
    v_started timestamptz; v_arrives timestamptz; v_holding timestamptz; v_returns timestamptz;
    v_prev text; v_new text; v_status text; v_n integer;
    v_a_m numeric; v_a_c numeric; v_a_d numeric;
    v_b_m numeric; v_b_c numeric; v_b_d numeric;
    v_db_m numeric; v_db_c numeric; v_db_d numeric;
    v_m numeric; v_c numeric; v_d numeric;
    v_ships integer;
    v_load record; v_ok boolean; v_fail integer := 0;
begin
    /* ------------------------------------------------------------------ FIXTURE */
    -- Origin: an auth-linked player's planet with NO other active movement, so the deterministic
    -- return settlement below is attributable to this fixture's fleet alone.
    select p.id, p.player_id, p.universe_id, pl.user_id
      into v_planet_a, v_player_a, v_universe_a, v_user_a
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where pl.user_id is not null
      and not p.is_destroyed
      and not exists (select 1 from public.fleet_movements fm
                       where fm.origin_planet_id = p.id and fm.status <> 'COMPLETED')
    order by p.is_homeworld desc, p.created_at, p.id
    limit 1;

    select p.player_id, p.id into v_player_b, v_planet_b
    from public.planets p
    where p.universe_id = v_universe_a
      and not p.is_destroyed
      and p.player_id <> v_player_a
    order by p.created_at, p.id
    limit 1;

    if v_planet_a is null or v_planet_b is null then
        raise exception 'TEST_ABORT: an auth-linked planet with no active movement and a foreign planet in the same universe are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);

    /* ============ A. ACL — internal calculation helpers closed to clients ============ */
    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('calculate_fleet_distance', 'calculate_fleet_travel_time')
      and (coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)=X/'
        or coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)anon=X'
        or coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)authenticated=X');
    v_ok := v_n = 0;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A1. calculate_fleet_distance / calculate_fleet_travel_time carry no PUBLIC+anon+authenticated grant [open=%s]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('calculate_mission_fleet_speed_multiplier', 'calculate_player_ship_speed',
                        'calculate_player_ship_fuel_consumption', 'calculate_player_fleet_fuel_for_distance',
                        'calculate_player_ship_cargo_capacity', 'calculate_fleet_cargo_capacity',
                        'calculate_fleet_distance_to_coordinates')
      and (coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)=X/'
        or coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)anon=X'
        or coalesce(array_to_string(p.proacl, ''), '') ~ '(^|,)authenticated=X');
    v_ok := v_n = 0;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A2. the rest of the canonical cluster stays closed to client roles [open=%s]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('start_fleet', 'start_fleet_mixed', 'start_colonize_fleet', 'start_support_fleet')
      and coalesce(array_to_string(p.proacl, ''), '') like '%authenticated=X%';
    v_ok := v_n = 4;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A3. the four dispatchers remain reachable by authenticated [granted=%s/4]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- The revoke must not break the internal path: the owner context still evaluates the formula.
    v_ok := public.calculate_fleet_travel_time(1000, 10000, 1, 100)
            = round(greatest(((35000::numeric / 100) * sqrt(1000::numeric * 10 / 10000::numeric) + 10) / 1, 1), 4);
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A4. the canonical travel-time formula still evaluates [%s]',
             public.calculate_fleet_travel_time(1000, 10000, 1, 100)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := public.calculate_fleet_distance(v_planet_a, v_planet_b) > 0;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A5. the canonical distance helper still resolves for the owner [%s]',
             public.calculate_fleet_distance(v_planet_a, v_planet_b)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ B. CARGO — TRANSPORT delivers once, never twice ============ */
    update public.planet_resources
       set metal = 500000, crystal = 500000, deuterium = 500000, last_calculated_at = now()
     where planet_id = v_planet_a;

    insert into public.planet_ships(planet_id, ship_id, quantity)
    values (v_planet_a, 'small_cargo', 5)
    on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, excluded.quantity);

    v_started := now() - interval '2 hours';
    v_arrives := now() - interval '1 hour';

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position)
    select v_player_a, v_planet_a, v_planet_b, 'TRANSPORT', v_started, v_arrives, 'OUTBOUND',
           p.galaxy, p.system, p.position
    from public.planets p where p.id = v_planet_b
    returning id into v_fleet_t;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet_t, 'small_cargo', 5);
    -- Mimic the dispatcher's ship debit so the return leg can be asserted exactly once.
    update public.planet_ships set quantity = quantity - 5
     where planet_id = v_planet_a and ship_id = 'small_cargo';

    select * into v_load from public.load_fleet_cargo(v_fleet_t, 1000, 2000, 3000);
    v_ok := v_load.metal = 1000 and v_load.crystal = 2000 and v_load.deuterium = 3000
        and v_load.total_cargo = 6000 and v_load.cargo_capacity >= 6000;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B1. cargo loaded through the canonical capacity contract [cargo=%s capacity=%s]',
             v_load.total_cargo, v_load.cargo_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select metal into v_a_m from public.planet_resources where planet_id = v_planet_a;

    -- Pin the destination clock to the arrival instant: zero elapsed production, so the delta is the cargo.
    update public.planet_resources set last_calculated_at = v_arrives where planet_id = v_planet_b;
    select metal, crystal, deuterium into v_b_m, v_b_c, v_b_d
      from public.planet_resources where planet_id = v_planet_b;

    -- The worker performs the OUTBOUND -> ARRIVED claim before invoking the resolver.
    update public.fleet_movements set status = 'ARRIVED' where id = v_fleet_t;

    perform public.resolve_transport_arrival(v_fleet_t);

    select metal, crystal, deuterium into v_m, v_c, v_d
      from public.planet_resources where planet_id = v_planet_b;
    v_ok := (v_m - v_b_m) = 1000 and (v_c - v_b_c) = 2000 and (v_d - v_b_d) = 3000;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B2. the destination is credited exactly once [delta %s/%s/%s]', v_m - v_b_m, v_c - v_b_c, v_d - v_b_d));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select status, metal, crystal, deuterium into v_status, v_m, v_c, v_d
      from public.fleet_movements where id = v_fleet_t;
    v_ok := v_status = 'RETURNING' and v_m = 0 and v_c = 0 and v_d = 0;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B3. the movement unloads its cargo at arrival (%s, cargo %s/%s/%s) so the return settlement cannot re-credit it',
             v_status, v_m, v_c, v_d));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select metal into v_m from public.planet_resources where planet_id = v_planet_a;
    v_ok := v_m = v_a_m;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'B4. the arrival leaves the origin planet untouched (delivery targets the destination only)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- Deterministic return settlement: the movement must be DUE (returns_at <= now) and the origin clock
    -- is pinned to returns_at, so the settlement adds zero production and any credit is the cargo itself.
    update public.fleet_movements set returns_at = now() - interval '1 minute' where id = v_fleet_t;
    select returns_at into v_returns from public.fleet_movements where id = v_fleet_t;
    update public.planet_resources set last_calculated_at = v_returns where planet_id = v_planet_a;
    select metal into v_a_m from public.planet_resources where planet_id = v_planet_a;

    v_prev := null; v_new := null;
    select r.previous_status, r.new_status into v_prev, v_new
      from public.process_fleet_movements() r where r.fleet_id = v_fleet_t;

    select status into v_status from public.fleet_movements where id = v_fleet_t;
    select metal into v_m from public.planet_resources where planet_id = v_planet_a;
    select quantity into v_ships from public.planet_ships
      where planet_id = v_planet_a and ship_id = 'small_cargo';
    v_ok := v_prev = 'RETURNING' and v_new = 'COMPLETED' and v_status = 'COMPLETED'
        and v_m = v_a_m and v_ships = 5;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B5. ...and the return credits 0 resources while restoring the ships exactly once [metal delta=%s, ships=%s]',
             v_m - v_a_m, v_ships));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ C. CARGO — ACS_HOLD keeps it through the hold and returns it home ============ */
    select metal, crystal, deuterium into v_db_m, v_db_c, v_db_d
      from public.planet_resources where planet_id = v_planet_b;

    v_started := now() - interval '2 hours';
    v_arrives := now() - interval '1 hour';
    v_holding := now() + interval '30 minutes';

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position,
        holding_until, idempotency_key)
    select v_player_a, v_planet_a, v_planet_b, 'ACS_HOLD', v_started, v_arrives, 'OUTBOUND',
           p.galaxy, p.system, p.position, v_holding, gen_random_uuid()
    from public.planets p where p.id = v_planet_b
    returning id into v_fleet_h;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet_h, 'small_cargo', 5);
    update public.planet_ships set quantity = quantity - 5
     where planet_id = v_planet_a and ship_id = 'small_cargo';

    update public.planet_resources set last_calculated_at = now() where planet_id = v_planet_a;
    select * into v_load from public.load_fleet_cargo(v_fleet_h, 100, 200, 300);
    v_ok := v_load.metal = 100 and v_load.crystal = 200 and v_load.deuterium = 300;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C1. a support (ACS_HOLD) fleet accepts cargo while OUTBOUND [%s/%s/%s]',
             v_load.metal, v_load.crystal, v_load.deuterium));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_prev := null; v_new := null;
    select r.previous_status, r.new_status into v_prev, v_new
      from public.process_fleet_movements() r where r.fleet_id = v_fleet_h;

    select status, metal, crystal, deuterium into v_status, v_m, v_c, v_d
      from public.fleet_movements where id = v_fleet_h;
    select metal, crystal, deuterium into v_b_m, v_b_c, v_b_d
      from public.planet_resources where planet_id = v_planet_b;
    v_ok := v_prev = 'OUTBOUND' and v_new = 'HOLDING' and v_status = 'HOLDING'
        and v_m = 100 and v_c = 200 and v_d = 300
        and v_b_m = v_db_m and v_b_c = v_db_c and v_b_d = v_db_d;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C2. OUTBOUND -> HOLDING preserves the cargo and never credits the supported planet [%s/%s/%s]',
             v_m, v_c, v_d));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.fleet_movements set holding_until = now() - interval '10 minutes' where id = v_fleet_h;

    v_prev := null; v_new := null;
    select r.previous_status, r.new_status into v_prev, v_new
      from public.process_fleet_movements() r where r.fleet_id = v_fleet_h;

    select status, returns_at, holding_until, metal, crystal, deuterium
      into v_status, v_returns, v_holding, v_m, v_c, v_d
      from public.fleet_movements where id = v_fleet_h;
    v_ok := v_prev = 'HOLDING' and v_new = 'RETURNING' and v_status = 'RETURNING'
        and v_returns = v_holding + (v_arrives - v_started)
        and v_m = 100 and v_c = 200 and v_d = 300;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C3. HOLDING -> RETURNING reuses the persisted outbound duration and keeps the cargo [returns_at=%s]', v_returns));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    -- Same determinism for the support return: make it due and pin the origin clock to the settlement.
    update public.fleet_movements set returns_at = now() - interval '1 minute' where id = v_fleet_h;
    select returns_at into v_returns from public.fleet_movements where id = v_fleet_h;
    update public.planet_resources set last_calculated_at = v_returns where planet_id = v_planet_a;
    select metal, crystal, deuterium into v_a_m, v_a_c, v_a_d
      from public.planet_resources where planet_id = v_planet_a;

    v_prev := null; v_new := null;
    select r.previous_status, r.new_status into v_prev, v_new
      from public.process_fleet_movements() r where r.fleet_id = v_fleet_h;

    select metal, crystal, deuterium into v_m, v_c, v_d
      from public.planet_resources where planet_id = v_planet_a;
    select status into v_status from public.fleet_movements where id = v_fleet_h;
    select quantity into v_ships from public.planet_ships
      where planet_id = v_planet_a and ship_id = 'small_cargo';
    v_ok := v_prev = 'RETURNING' and v_new = 'COMPLETED' and v_status = 'COMPLETED'
        and (v_m - v_a_m) = 100 and (v_c - v_a_c) = 200 and (v_d - v_a_d) = 300
        and v_ships = 5;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('C4. the cargo lands on the ORIGIN exactly once at COMPLETED [delta %s/%s/%s, ships=%s]',
             v_m - v_a_m, v_c - v_a_c, v_d - v_a_d, v_ships));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pr.metal, pr.crystal, pr.deuterium into v_b_m, v_b_c, v_b_d
      from public.planet_resources pr where pr.planet_id = v_planet_b;
    select metal, crystal, deuterium, status into v_m, v_c, v_d, v_status
      from public.fleet_movements where id = v_fleet_h;
    v_ok := v_b_m = v_db_m and v_b_c = v_db_c and v_b_d = v_db_d
        and v_m = 0 and v_c = 0 and v_d = 0 and v_status = 'COMPLETED';
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C5. the supported planet is never credited and the completed support movement is unloaded');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ D. Structural guards (transversal audit 2026-09-25) ============ */
    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%35000%';
    v_ok := v_n = 2;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('D1. exactly two implementations carry the 35000 constant (travel time + fuel) [%s]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.prosrc like '%u.fleet_speed%' or p.prosrc like '%universes.fleet_speed%');
    v_ok := v_n = 1;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('D2. the legacy fleet_speed column is read only by the informational snapshot [readers=%s]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('start_fleet', 'start_fleet_mixed', 'start_colonize_fleet', 'start_support_fleet')
      and p.prosrc like '%.speed%';
    v_ok := v_n = 0;
    insert into t_fleet_matrix_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('D3. no dispatcher bypasses the player-aware speed helper with ship_definitions.speed [%s]', v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_fleet_matrix_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness. Concurrency is not executed; the return settlement is made deterministic by pinning planet_resources.last_calculated_at to the settlement instant.');

    if v_fail > 0 then
        raise exception 'FLEET ENGINE HELPER ACL & HOLDING CARGO FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_fleet_matrix_results order by orden;

drop table if exists t_fleet_matrix_results;

ROLLBACK;
