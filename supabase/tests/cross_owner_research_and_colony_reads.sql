-- CROSS-OWNER RESEARCH / COLONY READ ORACLES — FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260927120000_harden_cross_owner_research_and_colony_reads):
--   get_research_network_lab_level(p_player_id, p_planet_id, p_research_id)
--   calculate_research_time(p_player_id, p_planet_id, p_research_id, p_target_level)
--   calculate_max_colony_slots(p_player_id)
--   check_colony_cap(p_player_id)
--   calculate_player_category_scores(p_player_id)
--
--   * as `authenticated`, a foreign player id -> 'PLAYER_NOT_OWNED_BY_AUTH_USER'
--     (check_colony_cap answers with a blocked ROW because that is its own shape),
--   * as `authenticated`, the caller's OWN player id together with a FOREIGN planet id ->
--     'PLANET_NOT_OWNED_BY_AUTH_USER' (otherwise the identity gate alone would leave the leak open),
--   * as `authenticated`, the caller's own player/planet -> unchanged behaviour,
--   * WITHOUT a JWT (the engine workers and the AI service actor) -> unchanged: the ownership gates only apply to an
--     authenticated session, which is what keeps process_fleet_movements / resolve_colonize_arrival /
--     recalculate_player_points / run_ranking_worker working (all of them are `authenticated = false`),
--   * ACL, SECURITY DEFINER and the pinned `search_path` are unchanged.
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_xo;
create temp table t_xo(orden serial, resultado text, prueba text);

do $test$
declare
    v_actor uuid; v_auth uuid; v_own uuid; v_foreign uuid; v_foreign_planet uuid;
    v_ok boolean; v_ok2 boolean; v_ok3 boolean; v_ok4 boolean;
    v_fail integer := 0; v_row record; v_row2 record;
begin
    select pl.id, pl.user_id into v_actor, v_auth from public.players pl
     where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_own from public.planets p
     where p.player_id = v_actor and not p.is_destroyed order by p.created_at limit 1;
    select p.player_id, p.id into v_foreign, v_foreign_planet from public.planets p
     where p.player_id is not null and p.player_id <> v_actor and not p.is_destroyed order by p.created_at limit 1;

    if v_own is null or v_foreign is null or v_auth is null then
        raise exception 'TEST_ABORT: needs the auth-linked player, one own planet and one foreign owned planet';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ============ 1..3. AS THE AUTHENTICATED ACTOR ============ */
    set local role authenticated;

    /* 1. every contract refuses a FOREIGN player id */
    v_ok := true;
    begin
        perform public.get_research_network_lab_level(v_foreign, v_foreign_planet, 'espionage_technology');
        v_ok := false;
    exception when others then v_ok := (sqlerrm = 'PLAYER_NOT_OWNED_BY_AUTH_USER');
    end;
    begin
        perform public.calculate_research_time(v_foreign, v_foreign_planet, 'espionage_technology', 1);
        v_ok := false;
    exception when others then v_ok := v_ok and (sqlerrm = 'PLAYER_NOT_OWNED_BY_AUTH_USER');
    end;
    begin
        perform public.calculate_max_colony_slots(v_foreign);
        v_ok := false;
    exception when others then v_ok := v_ok and (sqlerrm = 'PLAYER_NOT_OWNED_BY_AUTH_USER');
    end;
    begin
        perform public.calculate_player_category_scores(v_foreign);
        v_ok := false;
    exception when others then v_ok := v_ok and (sqlerrm = 'PLAYER_NOT_OWNED_BY_AUTH_USER');
    end;
    begin
        select * into v_row from public.check_colony_cap(v_foreign);
        v_ok := v_ok and v_row.allowed = false
                and v_row.reason = 'PLAYER_NOT_OWNED_BY_AUTH_USER'
                and v_row.max_slots is null and v_row.current_planets is null and v_row.astrophysics_level is null;
    exception when others then v_ok := false;
    end;

    /* 2. the own-player + FOREIGN-planet combination must not slip through the identity gate */
    v_ok2 := true;
    begin
        perform public.get_research_network_lab_level(v_actor, v_foreign_planet, 'espionage_technology');
        v_ok2 := false;
    exception when others then v_ok2 := (sqlerrm = 'PLANET_NOT_OWNED_BY_AUTH_USER');
    end;
    begin
        perform public.calculate_research_time(v_actor, v_foreign_planet, 'espionage_technology', 1);
        v_ok2 := false;
    exception when others then v_ok2 := v_ok2 and (sqlerrm = 'PLANET_NOT_OWNED_BY_AUTH_USER');
    end;

    /* 3. the owner path is unchanged */
    v_ok3 := true;
    begin
        perform public.get_research_network_lab_level(v_actor, v_own, 'espionage_technology');
        perform public.calculate_research_time(v_actor, v_own, 'espionage_technology', 1);
        perform public.calculate_max_colony_slots(v_actor);
        perform public.calculate_player_category_scores(v_actor);
        select * into v_row2 from public.check_colony_cap(v_actor);
        v_ok3 := v_row2.allowed is not null and v_row2.reason is not null and v_row2.max_slots >= 1;
    exception when others then v_ok3 := false;
    end;

    reset role;

    insert into t_xo(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. as `authenticated`, all five contracts refuse a FOREIGN player id with PLAYER_NOT_OWNED_BY_AUTH_USER, and check_colony_cap leaks no number');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_xo(resultado, prueba) values (case when v_ok2 then 'PASS' else 'FAIL' end,
      '2. own-player + FOREIGN-planet is refused with PLANET_NOT_OWNED_BY_AUTH_USER: the lab level of a foreign planet is not readable');
    v_fail := v_fail + case when v_ok2 then 0 else 1 end;

    insert into t_xo(resultado, prueba) values (case when v_ok3 then 'PASS' else 'FAIL' end,
      format('3. the owner path still works (colony cap %s, reason %s)', v_row2.max_slots, v_row2.reason));
    v_fail := v_fail + case when v_ok3 then 0 else 1 end;

    /* ============ 4. THE ENGINE / AI PATH (NO JWT) IS UNCHANGED ============ */
    perform set_config('request.jwt.claims', '', true);

    v_ok4 := true;
    begin
        select * into v_row from public.check_colony_cap(v_foreign);
        v_ok4 := v_row.allowed is not null and v_row.astrophysics_level is not null;
    exception when others then v_ok4 := false;
    end;
    begin
        perform public.calculate_max_colony_slots(v_foreign);
        perform public.calculate_player_category_scores(v_foreign);
        perform public.get_research_network_lab_level(v_foreign, v_foreign_planet, 'espionage_technology');
    exception when others then v_ok4 := false;
    end;
    insert into t_xo(resultado, prueba) values (case when v_ok4 then 'PASS' else 'FAIL' end,
      '4. without a JWT (ranking workers, colonize resolver, AI service actor) the same calls still resolve a foreign player: the gate only applies to an authenticated session');
    v_fail := v_fail + case when v_ok4 then 0 else 1 end;

    /* ============ 5. ACL, SECURITY DEFINER AND THE PINNED search_path ============ */
    v_ok := not has_function_privilege('anon', 'public.get_research_network_lab_level(uuid,uuid,text)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_research_time(uuid,uuid,text,integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_max_colony_slots(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.check_colony_cap(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_player_category_scores(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.check_colony_cap(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.calculate_research_time(uuid,uuid,text,integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.calculate_player_category_scores(uuid)', 'EXECUTE')
            and (select count(*) from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname in ('get_research_network_lab_level', 'calculate_research_time',
                                      'calculate_max_colony_slots', 'check_colony_cap',
                                      'calculate_player_category_scores')
                    and p.prosecdef
                    and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public, pg_temp%') >= 5;
    insert into t_xo(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. ACL unchanged (never anon, authenticated + service_role only) and every hardened function is SECURITY DEFINER with search_path = public, pg_temp');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 6. NO PUBLIC GRANT ON THE HARDENED SURFACE ============ */
    v_ok := (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname in ('get_research_network_lab_level', 'calculate_research_time',
                                  'calculate_max_colony_slots', 'check_colony_cap',
                                  'calculate_player_category_scores')
                and coalesce(p.proacl::text, '') like '%{=X/%') = 0;
    insert into t_xo(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. no hardened function carries an ACL-level PUBLIC grant any more');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_xo(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; the concurrency case is not executed.');

    if v_fail > 0 then
        raise exception 'CROSS-OWNER READ FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) filter (where resultado <> 'INFO') as assertions
  from t_xo;

select orden, resultado, prueba from t_xo order by orden;

drop table if exists t_xo;

rollback;
