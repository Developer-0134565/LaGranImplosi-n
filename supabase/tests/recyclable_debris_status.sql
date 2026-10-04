-- RECYCLABLE DEBRIS STATUS CONTRACT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260928220000): `get_recyclable_debris_status()` — EXISTENCE ONLY.
--
-- Gap closed 2026-09-28: the RECYCLE mission selects its target SERVER-SIDE (the player may not send
-- coordinates) and `start_fleet_mixed` raises 'No debris field available for RECYCLE' when no non-empty
-- field exists. That refusal is already correct and atomic; what was missing is that the player only
-- learned it AFTER pressing launch, while every other blocked mission is surfaced up front.
--
-- The point of this fixture is that EXISTENCE-ONLY is EXACT, not a weakening: the contract's predicate
-- IS the dispatcher's precondition. So `available = false` implies the engine WILL refuse, and
-- `available = true` implies the engine WILL find a target. No distance, range or capacity is asserted,
-- because the contract deliberately models none of them.
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed.

begin;

drop table if exists t_rds;
create temp table t_rds(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_universe uuid; v_planet uuid; v_other_universe uuid;
    v_og int; v_os int; v_op int;
    v_row record; v_ok boolean; v_fails integer := 0; v_err text; v_moves integer; v_moves_before integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id, p.galaxy, p.system, p.position into v_planet, v_og, v_os, v_op
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.created_at limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    /* the player universe starts with NO debris, whatever the rest of the database contains */
    delete from public.debris_fields where universe_id = v_universe;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    /* `check_ship_requirements` gates `recycler` on a shipyard 4 AND combustion_drive 6. Without both,
       the POSITIVE half of the fixture (test 4) would fail for an unrelated reason and prove nothing. */
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'shipyard', 4)
      on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'combustion_drive', 6)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 6);
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'recycler', 3)
      on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 3);
    update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;

    /* 1. no debris in my universe -> available = false */
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := not v_row.out_available and v_row.out_field_count = 0;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. empty universe -> available=%s fields=%s', v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 2. ...and the engine really does refuse, exactly as the UI now predicts */
    /* Measured as a DELTA (before/after), never as an absolute total: LIVE may already hold RECYCLE
       rows for this player, and only the change is attributable to this call. Comparing against 0
       asserted "this player has never recycled", which is a statement about the DATABASE, not about
       the engine, and it failed against LIVE for reasons unrelated to the contract. */
    select count(*)::integer into v_moves_before from public.fleet_movements
     where player_id = v_player and mission_type = 'RECYCLE';
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, null, '{"recycler": 1}'::jsonb, 'RECYCLE');
    exception when others then v_err := sqlerrm; end;
    select count(*)::integer into v_moves from public.fleet_movements
     where player_id = v_player and mission_type = 'RECYCLE';
    v_ok := v_err ilike '%No debris field available for RECYCLE%' and v_moves = v_moves_before;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. the engine confirms the same answer and stays atomic (%s, %s -> %s movements)',
             coalesce(v_err,'ACCEPTED'), v_moves_before, v_moves));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---- THE POSITIVE HALF. Everything above ran on an empty universe, so it only ever proved
       the NEGATIVE answer. A real field is created HERE, after assertion 2, because assertion 2
       must observe the engine refusing precisely when the universe is empty.
       `debris_fields` was emptied for this universe above and
       `debris_fields_unique_coordinate` is (universe_id, galaxy, system, position), so the
       origin coordinate is provably free here and the field is guaranteed to be the one the
       dispatcher finds. Without this INSERT the whole rest of the fixture silently degenerated:
       the UPDATEs in assertions 5 and 6 touched ZERO rows, and 7b expected a field that had
       never been created (it failed LIVE: available=f fields=0). */
    insert into public.debris_fields(universe_id, galaxy, system, position, metal, crystal)
    values (v_universe, v_og, v_os, v_op, 5000, 2500);

    /* 3. MY OWN debris -> visible. This is the answer the UI actually renders. */
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := v_row.out_available and v_row.out_field_count = 1;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. my own debris field is visible (available=%s fields=%s)',
             v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 4. ...and the engine then ACCEPTS the very dispatch the UI just stopped blocking. This is the
       no-regression half: the contract is only a hint, so the existing RECYCLE flow must be intact.
       Counted as a DELTA (before/after), never as an absolute total: LIVE may already hold RECYCLE
       rows for this player, and only the change is attributable to this call. */
    select count(*)::integer into v_moves from public.fleet_movements
     where player_id = v_player and mission_type = 'RECYCLE';
    v_err := null;
    begin
        perform public.start_fleet_mixed(v_player, v_planet, null, '{"recycler": 1}'::jsonb, 'RECYCLE');
    exception when others then v_err := sqlerrm; end;
    insert into t_rds(resultado, prueba) values (case when v_err is null then 'PASS' else 'FAIL' end,
      format('4. with my own debris the engine ACCEPTS the dispatch (%s, %s RECYCLE movement(s) before)',
             coalesce(v_err,'ACCEPTED'), v_moves));
    v_fails := v_fails + case when v_err is null then 0 else 1 end;

    /* 5. an EMPTY field (0/0) does not count: it is exactly the dispatcher's (metal>0 OR crystal>0) */
    update public.debris_fields set metal = 0, crystal = 0 where universe_id = v_universe;
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := not v_row.out_available and v_row.out_field_count = 0;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. an exhausted (0/0) field is not recyclable (available=%s fields=%s)',
             v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 6. no session -> the answer is a hard "no". The contract is an aggregate without GROUP BY, so it
          always returns exactly ONE row; the meaningful assertion is the VALUE, not the row count. */
    update public.debris_fields set metal = 5000, crystal = 2500 where universe_id = v_universe;
    perform set_config('request.jwt.claims', '{}', true);
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := not v_row.out_available and v_row.out_field_count = 0;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. without a session the answer is a hard NO (available=%s fields=%s)',
             v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* 7. OWNERSHIP: a player of ANOTHER universe sees 0 rows, never my fields. A real second
          universe is used, because players.universe_id is a foreign key. */
    /* `universes.name` has no UNIQUE constraint, so `on conflict do nothing` never fires: a random
       name is used instead and the row is referenced by that exact name. */
    insert into public.universes(name)
    values ('RdsOtherUniverse-' || gen_random_uuid()::text)
    returning id into v_other_universe;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'rdsother@example.invalid', crypt('Rdsother!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '');
    insert into public.players(universe_id, user_id, username, is_guest, player_type)
    values (v_other_universe,
            (select id from auth.users where email = 'rdsother@example.invalid'),
            'RdsOther', false, 'HUMAN');
    perform set_config('request.jwt.claims', json_build_object('sub',
            (select id from auth.users where email = 'rdsother@example.invalid')::text)::text, true);
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := not v_row.out_available and v_row.out_field_count = 0;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. a player of ANOTHER universe gets a hard NO, never my fields (available=%s fields=%s)',
             v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* 7b. and the owner still sees its own field, proving the "no" above is isolation, not a bug */
    select * into v_row from public.get_recyclable_debris_status();
    v_ok := v_row.out_available and v_row.out_field_count = 1;
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7b. the owner still sees its own field (available=%s fields=%s)',
             v_row.out_available, v_row.out_field_count));
    v_fails := v_fails + case when v_ok then 0 else 1 end;


    /* 8. no manipulable parameter: the contract takes NO arguments */
    v_ok := (select pg_get_function_arguments(p.oid) = ''
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_recyclable_debris_status');
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. the contract takes NO arguments: nothing to manipulate');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 9. read-only, and it models no distance/range/capacity (existence only, by construction) */
    v_ok := (select p.prosrc::text !~* '\m(insert|update|delete|truncate)\M'
               and p.prosrc::text !~* '\m(distance|range|capacity|order by|limit)\M'
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_recyclable_debris_status');
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. read-only and existence-only: no write path, no distance/range/capacity/ranking');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 10. ACL: authenticated + service_role, never anon */
    v_ok := has_function_privilege('authenticated', 'public.get_recyclable_debris_status()', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_recyclable_debris_status()', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_recyclable_debris_status()', 'EXECUTE');
    insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. ACL: authenticated + service_role, anon denied');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 11. the recycling ENGINE was not changed: it must not depend on the new contract.
       R2-11 REPAIR. The previous check was a bare substring search for
       'get_recyclable_debris_status' over the ENGINE's prosrc. That is not a dependency test, it is
       a text search, and 20261002000000 legitimately added an explanatory COMMENT inside
       `collect_debris` that names the contract — so the search matched PROSE and reported a
       dependency that does not exist. The check now distinguishes EXECUTABLE CODE from comments:
       SQL comments (`-- ...` and nested-free `/* ... */`) are stripped, whitespace is normalised,
       and what is then required is the absence of an actual CALL, i.e. the identifier followed by
       `(`. A bare mention in a comment is not a call, and a real call is still caught.
       This is deliberately NOT "delete every occurrence and declare PASS": the very same stripped
       form is asserted to STILL DETECT a genuine call, so the check cannot pass by construction.
       The anti-vacuity meta-control below proves the detector works in both directions. */
    declare v_engine_src text; v_engine_code text; v_offenders text;
            v_detects_call boolean; v_ignores_comment boolean;
    begin
        select string_agg(p.prosrc, E'\n') into v_engine_src
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('start_fleet_mixed','collect_debris','calculate_recycler_capacity','can_recycle_debris');

        /* strip comments, then collapse whitespace: this is the "code only" view */
        v_engine_code := regexp_replace(regexp_replace(coalesce(v_engine_src, ''), '/\*.*?\*/', '', 'gs'),
                                        '--[^\n\r]*', '', 'g');

        /* ANTI-VACUITY: the identical transformation, applied to a synthetic source that really
           does CALL the contract, must still detect it. Without this the assertion below would be
           unfalsifiable. */
        v_detects_call :=
            regexp_replace(regexp_replace(
                $$DECLARE v boolean; BEGIN PERFORM public.get_recyclable_debris_status(); END;$$,
                '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g')
            ~* 'get_recyclable_debris_status\s*\(';
        /* ...and the same transformation applied to a comment-only mention must NOT detect it. */
        v_ignores_comment :=
            not (regexp_replace(regexp_replace(
                $$-- this engine deliberately avoids get_recyclable_debris_status()
                   DECLARE v boolean; BEGIN v := true; END;$$,
                '/\*.*?\*/', '', 'gs'), '--[^\n\r]*', '', 'g')
            ~* 'get_recyclable_debris_status\s*\(');

        select string_agg(p.proname, ',') into v_offenders
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('start_fleet_mixed','collect_debris','calculate_recycler_capacity','can_recycle_debris')
           and regexp_replace(regexp_replace(coalesce(p.prosrc,''), '/\*.*?\*/', '', 'gs'),
                              '--[^\n\r]*', '', 'g') ~* 'get_recyclable_debris_status\s*\(';

        v_ok := v_detects_call and v_ignores_comment and v_offenders is null;
        insert into t_rds(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('11. the recycling engine does not CALL the new contract: executable callers=%s. '
                 ||'Detector validated in both directions (detects a real call=%s, ignores a comment=%s), '
                 ||'so a comment mentioning the contract is no longer a false positive',
                 coalesce(v_offenders,'none'), v_detects_call, v_ignores_comment));
        v_fails := v_fails + case when v_ok then 0 else 1 end;
    end;

    insert into t_rds(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The UI only renders this boolean; the engine still decides the target.');
    insert into t_rds(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fails));
    if v_fails > 0 then
        raise exception 'RECYCLABLE DEBRIS STATUS: % failed assertion(s)', v_fails;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rds order by orden;

drop table if exists t_rds;

ROLLBACK;
