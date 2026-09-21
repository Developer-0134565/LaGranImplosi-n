-- ============================================================================
-- COMBAT ENGINE PHASE 2 — CB-03 DEBRIS IDEMPOTENCY FIXTURE
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Proves the Phase 2 debris invariant:
--
--   one battle -> one authoritative debris generation -> one field credit
--
--   C1  the first resolution credits the target coordinate exactly once, by the
--       persisted generation amount (field delta == metal_generated)
--   C2  re-entering `create_combat_debris` returns already_generated = true,
--       credits nothing and keeps a single generation row
--   C3  a third invocation behaves identically (replay-stable)
--   C4  the battle-scoped advisory lock and the observable conflict branch are
--       present in the LIVE definition (structural proof of the concurrency guard;
--       two concurrent sessions cannot be created from this environment)
--   C5  the function stays internal (no anon/authenticated EXECUTE)
--
-- ROLLBACK SAFETY: the battle, the fleet and the field credit all live inside a
-- nested PL/pgSQL block undone by a sentinel exception, so LIVE keeps its
-- pre-existing debris fields and no battle residue remains.
-- ============================================================================

begin;

drop table if exists t_combat_debris_results;
create temp table t_combat_debris_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid;
    v_target uuid; v_galaxy integer; v_system integer; v_position integer;
    v_fleet uuid := gen_random_uuid();
    v_battle uuid;
    v_metal_before numeric; v_metal_after_first numeric;
    v_metal_after_second numeric; v_metal_after_third numeric;
    v_generated numeric; v_generations bigint;
    v_already_first boolean; v_already_second boolean;
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

        select p2.id, p2.galaxy, p2.system, p2.position
          into v_target, v_galaxy, v_system, v_position
        from public.planets p2
        where p2.universe_id = v_universe and p2.is_destroyed = false
          and p2.player_id <> v_player and p2.id <> v_origin
        order by p2.galaxy, p2.system, p2.position, p2.id
        limit 1;

        select coalesce(sum(df.metal), 0) into v_metal_before
        from public.debris_fields df
        where df.universe_id = v_universe and df.galaxy = v_galaxy
          and df.system = v_system and df.position = v_position;

        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_fleet, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '60 seconds',
                clock_timestamp() - interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_fleet, 'cruiser', 20);

        v_battle := public.resolve_attack_arrival(v_fleet);

        /* ---- C1: exactly one credit, equal to the persisted generation ----- */
        select coalesce(sum(df.metal), 0) into v_metal_after_first
        from public.debris_fields df
        where df.universe_id = v_universe and df.galaxy = v_galaxy
          and df.system = v_system and df.position = v_position;

        select count(*), coalesce(max(g.metal_generated), 0)
          into v_generations, v_generated
        from public.combat_debris_generations g
        where g.battle_id = v_battle;

        v_ok := v_generations = 1 and v_generated > 0
                and v_metal_after_first = v_metal_before + v_generated;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('C1 one generation row (%s) credited once (generated=%s delta=%s)',
                      v_generations, v_generated, v_metal_after_first - v_metal_before) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- C2: re-entry is a no-op -------------------------------------- */
        select x.out_already_generated into v_already_first
        from public.create_combat_debris(v_battle) x;

        select coalesce(sum(df.metal), 0) into v_metal_after_second
        from public.debris_fields df
        where df.universe_id = v_universe and df.galaxy = v_galaxy
          and df.system = v_system and df.position = v_position;

        select count(*) into v_generations from public.combat_debris_generations where battle_id = v_battle;

        v_ok := v_already_first and v_metal_after_second = v_metal_after_first and v_generations = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('C2 re-entry no-op (already_generated=%s delta=%s generations=%s)',
                      v_already_first, v_metal_after_second - v_metal_after_first, v_generations) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- C3: replay-stable -------------------------------------------- */
        select x.out_already_generated into v_already_second
        from public.create_combat_debris(v_battle) x;

        select coalesce(sum(df.metal), 0) into v_metal_after_third
        from public.debris_fields df
        where df.universe_id = v_universe and df.galaxy = v_galaxy
          and df.system = v_system and df.position = v_position;

        v_ok := v_already_second and v_metal_after_third = v_metal_after_second;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('C3 replay stable (already_generated=%s delta=%s)',
                      v_already_second, v_metal_after_third - v_metal_after_second) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- C4: concurrency guard present -------------------------------- */
        select (position('pg_advisory_xact_lock(hashtextextended' in prosrc) > 0
                and position('COMBAT_DEBRIS_CONFLICT' in prosrc) > 0)
          into v_ok
        from pg_proc
        where pronamespace = 'public'::regnamespace and proname = 'create_combat_debris';

        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'C4 battle-scoped advisory lock and observable conflict branch present' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- C5: the generator stays internal ----------------------------- */
        v_ok := (not has_function_privilege('anon', 'public.create_combat_debris(uuid)', 'EXECUTE'))
                and (not has_function_privilege('authenticated', 'public.create_combat_debris(uuid)', 'EXECUTE'));

        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'C5 create_combat_debris is not executable by client roles' || E'\n';
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

    insert into t_combat_debris_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT DEBRIS IDEMPOTENCY FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT DEBRIS IDEMPOTENCY FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_debris_results order by orden;

drop table if exists t_combat_debris_results;

rollback;
