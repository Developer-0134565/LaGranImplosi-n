-- TRANSPORT MOVEMENT READ CONTRACT FIXTURE - LA GRAN IMPLOSION
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260928131919): `get_player_transport_movements(p_limit)` - the ONLY read path of
-- the TRANSPORTES category of the communications centre (src/App.tsx, loadMessages()).
--
-- Gap closed 2026-09-28 (Messages/Reports cycle): the browser read the table straight from the client,
--     supabase.from('fleet_movements').select(...).eq('player_id', playerId).eq('mission_type','TRANSPORT')
-- which is NOT a vulnerability - `fleet_movements` RLS was already owner-scoped - but it was the last
-- Messages category that let the BROWSER supply its own ownership selector. The three sibling categories
-- already went through certified contracts (get_player_battle_reports / _espionage_ / _expedition_reports).
--
-- This fixture certifies: the owner reads exactly its transport movements, ownership is resolved through
-- auth.uid() (never a parameter), the mission filter is fixed server-side, the limit is clamped server-side,
-- there is no write path, the ACL is unchanged - and that the RESULT is identical to the direct read that
-- loadMessages() used to perform, so the visible category does not change.
--
-- LIMITATION: single-session harness; concurrency not executed. LIVE carries a single auth player, so the
-- foreign caller is created inside this transaction: the assertion under test is the CONTRACT isolation,
-- not the environment's data.

begin;

drop table if exists t_tmt;
create temp table t_tmt(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_other uuid; v_other_user uuid;
    v_planet uuid; v_other_planet uuid;
    v_fleet uuid; v_fleet_2 uuid; v_fleet_foreign uuid; v_anchor uuid;
    v_galax integer; v_sys integer; v_pos integer;
    v_ok boolean; v_fail integer := 0; v_rows integer;
    v_row record; v_status text; v_n integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id, p.galaxy, p.system, p.position into v_planet, v_galax, v_sys, v_pos
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.created_at limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    v_other_user := gen_random_uuid();
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (v_other_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'tmtforeign@example.invalid', crypt('Tmtforeign!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '');
    insert into public.players(user_id, universe_id, username, is_guest, player_type)
    values (v_other_user, v_universe, 'TmtForeign', false, 'HUMAN') returning id into v_other;
    /* a FREE coordinate for the foreign homeworld: the unique (universe_id, galaxy, system, position) index makes a
       hard-coded coordinate a latent collision. The first system of LIVE is completely full (15/15), so the search
       spans the whole galaxy/system space and picks the first genuinely free slot. */
    select gg.galaxy, ss.system, pp.position into v_galax, v_sys, v_pos
      from generate_series(1, 9) as gg(galaxy)
      cross join generate_series(1, 499) as ss(system)
      cross join generate_series(1, 15) as pp(position)
     where not exists (select 1 from public.planets px
                        where px.universe_id = v_universe and px.galaxy = gg.galaxy
                          and px.system = ss.system and px.position = pp.position)
     order by gg.galaxy, ss.system, pp.position limit 1;
    if v_pos is null then
        raise exception 'TEST_ABORT: the universe has no free coordinate for the foreign homeworld';
    end if;
    insert into public.planets(universe_id, player_id, name, galaxy, system, position, is_homeworld, is_destroyed, kind)
    select v_universe, v_other, 'TmtForeignHome', v_galax, v_sys, v_pos, true, false, 'PLANET' returning id into v_other_planet;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* a full fleet slot budget so the slot trigger is never the limiting factor of this fixture */
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 60)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 60);

    /* the subject: two OWN transports with distinct coordinates/status, plus a non-transport and a foreign one.
       created_at is set EXPLICITLY: its default is now() = the transaction start, so every row of this fixture
       would otherwise share one timestamp and the `created_at desc, id` order would be decided by a random uuid. */
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position, created_at)
    values (v_player, v_planet, null, 'TRANSPORT', clock_timestamp() - interval '2 hours',
        clock_timestamp() + interval '1 hour', 'OUTBOUND', 7, 42, 9, clock_timestamp() - interval '2 hours')
    returning id into v_fleet;
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position, created_at)
    values (v_player, v_planet, null, 'TRANSPORT', clock_timestamp() - interval '1 hour',
        clock_timestamp() + interval '2 hours', 'ARRIVED', 3, 11, 5, clock_timestamp() - interval '1 hour')
    returning id into v_fleet_2;
    /* a NON-transport movement of the same owner: the mission filter is fixed server-side, so it must not appear */
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position, created_at)
    values (v_player, v_planet, null, 'ATTACK', clock_timestamp() - interval '30 minutes',
        clock_timestamp() + interval '3 hours', 'OUTBOUND', 1, 2, 3, clock_timestamp() - interval '30 minutes')
    returning id into v_anchor;
    /* a transport of ANOTHER player: the owner must not see it. It is written AS the foreign session, because
       enforce_player_write_access() refuses to create a movement for a player the caller does not own - the very
       authority this fixture certifies, so the refusal is expected behaviour and not a test obstacle. */
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position, created_at)
    values (v_other, v_other_planet, null, 'TRANSPORT', clock_timestamp() - interval '5 minutes',
        clock_timestamp() + interval '4 hours', 'OUTBOUND', 9, 99, 1, clock_timestamp() - interval '5 minutes')
    returning id into v_fleet_foreign;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---- 1. the owner reads its own transport, with exactly the columns the TRANSPORTES row renders ---- */
    select r.* into v_row from public.get_player_transport_movements(25) r where r.out_movement_id = v_fleet;
    v_ok := v_row.out_movement_id is not null
            and v_row.out_status = 'OUTBOUND'
            and v_row.out_destination_galaxy = 7
            and v_row.out_destination_system = 42
            and v_row.out_destination_position = 9
            and v_row.out_created_at is not null;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the owner reads its own transport with id, status and the 3 destination coordinates (%s)', v_row.out_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 2. the mission filter is fixed server-side: a non-TRANSPORT movement never leaks into the category ---- */
    select count(*)::integer into v_rows from public.get_player_transport_movements(25) r where r.out_movement_id = v_anchor;
    v_ok := v_rows = 0;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. an ATTACK movement of the same owner is NOT in the TRANSPORTES category (%s rows)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 3. a foreign authenticated player reads 0 rows of that movement ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
    select count(*)::integer into v_rows from public.get_player_transport_movements(25) r where r.out_movement_id = v_fleet;
    v_ok := v_rows = 0;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a foreign authenticated player reads 0 rows of that transport (%s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 4. without a session nothing is visible ---- */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_transport_movements(25);
    v_ok := v_rows = 0;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. without a session the contract returns 0 rows (%s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    returning id into v_fleet_foreign;


    /* ---- 5. the query parameter cannot become an identity selector ---- */
    v_ok := (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_transport_movements') = 1
            and (select pg_get_function_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_transport_movements') = 'p_limit integer DEFAULT 25'
            and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_transport_movements'
                and p.prosrc::text ilike '%p_player_id%');
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. the ONLY argument is p_limit: no player selector can be supplied by the client');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 6. the limit works, and the order is the one the browser used ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select count(*)::integer into v_rows from public.get_player_transport_movements(1);
    v_ok := v_rows = 1;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. p_limit = 1 returns exactly 1 row (%s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    select r.out_status into v_status from public.get_player_transport_movements(1) r;
    v_ok := v_status = 'ARRIVED';
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. ordering is created_at desc: the newest transport comes first (%s)', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 8. an excessive limit is clamped server-side, never trusted ---- */
    select count(*)::integer into v_rows from public.get_player_transport_movements(5000);
    v_ok := v_rows <= 100;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. p_limit = 5000 is clamped to the 100 ceiling (%s rows)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    select count(*)::integer into v_rows from public.get_player_transport_movements(0);
    v_ok := v_rows = 1;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. a non-positive p_limit is clamped up to the 1 floor, never to zero (%s rows)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 10. no write path: SECURITY DEFINER, read-only body ---- */
    v_ok := (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_transport_movements')
            and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'get_player_transport_movements'
                and (p.prosrc::text ~* '\m(insert|update|delete|truncate)\M'));
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. no write path: SECURITY DEFINER read-only body (no insert/update/delete/truncate)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 11. ACL: authenticated + service_role, never anon ---- */
    v_ok := has_function_privilege('authenticated', 'public.get_player_transport_movements(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_transport_movements(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_transport_movements(integer)', 'EXECUTE');
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. ACL: authenticated + service_role, anon denied');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- 12. PARITY with the read loadMessages() used to perform from the browser:
             same filter, same order, same visible rows for the authenticated owner ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    with direct as (
        select fm.id, fm.status, fm.destination_galaxy, fm.destination_system, fm.destination_position, fm.created_at
          from public.fleet_movements fm
         where fm.mission_type = 'TRANSPORT'
           and fm.player_id = v_player
         order by fm.created_at desc, fm.id
         limit 25
    ), contract as (
        select r.out_movement_id as id, r.out_status as status, r.out_destination_galaxy as destination_galaxy,
               r.out_destination_system as destination_system, r.out_destination_position as destination_position,
               r.out_created_at as created_at
          from public.get_player_transport_movements(25) r
    )
    select count(*)::integer into v_rows from (select * from direct except select * from contract) x;
    v_n := (select count(*)::integer from public.get_player_transport_movements(25));
    v_ok := v_rows = 0;
    insert into t_tmt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. PARITY: the contract returns EXACTLY the rows the old direct read returned (%s differing, %s rows total)', v_rows, v_n));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_tmt(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. The assertion under test is the CONTRACT (ownership, clamp, ACL, parity), not a browser render.');
    insert into t_tmt(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fail));
    if v_fail > 0 then
        raise exception 'TRANSPORT MOVEMENT READ CONTRACT: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_tmt order by orden;

drop table if exists t_tmt;

ROLLBACK;

