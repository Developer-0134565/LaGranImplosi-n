-- COLONY CAP (astrophysics) FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926210000_colony_cap_astrophysics.sql), OGameX MAX_COLONIES parity:
--   max PLANETS = 1 homeworld + max(1, round(astrophysics / 2)); moons and destroyed planets never count;
--   enforced at dispatch (start_colonize_fleet) and at creation (resolve_colonize_arrival).
-- LIMITATION: single-session harness; concurrency is not executed (the arrival gate is the defensive one).

begin;

drop table if exists t_cc;
create temp table t_cc(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_origin uuid; v_extra uuid; v_moon uuid;
    v_ok boolean; v_fail integer := 0; v_raised text; v_slots integer;
    v_inspect record; v_g integer; v_s integer; v_p integer; v_i integer; v_current integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_origin from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;

    if v_player is null or v_origin is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    delete from public.planets where parent_planet_id = v_origin;
    delete from public.planets where player_id = v_player and id <> v_origin and not is_destroyed;
    delete from public.player_research where player_id = v_player and research_id = 'astrophysics';

    /* 1. the OGameX-derived curve (1 homeworld + max(1, round(astro/2))) */
    v_ok := public.calculate_max_colony_slots(v_player) = 2;
    insert into public.player_research(player_id, research_id, level) values (v_player, 'astrophysics', 4);
    v_ok := v_ok and public.calculate_max_colony_slots(v_player) = 3;
    update public.player_research set level = 10 where player_id = v_player and research_id = 'astrophysics';
    v_ok := v_ok and public.calculate_max_colony_slots(v_player) = 6;
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. slots astro 0/4/10 = 2/3/6 (now %s at astro 10)', public.calculate_max_colony_slots(v_player)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. a single-planet player is always allowed to colonize */
    update public.player_research set level = 0 where player_id = v_player and research_id = 'astrophysics';
    select * into v_inspect from public.check_colony_cap(v_player);
    v_ok := v_inspect.allowed and v_inspect.max_slots = 2 and v_inspect.current_planets = 1
            and v_inspect.reason = 'OK' and v_inspect.astrophysics_level = 0;
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. cap %s with %s planet(s) at astro %s -> %s', v_inspect.max_slots, v_inspect.current_planets,
             v_inspect.astrophysics_level, v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. a second planet fills the cap; a moon never counts against it */
    v_extra := null;
    for v_i in 1..20 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total, fields_used, is_homeworld, is_destroyed, kind)
            select v_universe, v_player, 'Cap' || v_i, o.galaxy, 460 + ((v_i - 1) % 20), 1 + ((v_i - 1) / 20), 100, 0, false, false, 'PLANET'
              from (select galaxy from public.planets where id = v_origin) o
            returning id into v_extra;
            exit;
        exception when unique_violation then v_extra := null; end;
    end loop;

    if v_extra is null then
        raise exception 'TEST_ABORT: no free coordinates for the extra planet';
    end if;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min, temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_player, 'CapMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false, 'MOON', p.id, 5000
      from public.planets p where p.id = v_origin
    returning id into v_moon;

    select * into v_inspect from public.check_colony_cap(v_player);
    v_ok := not v_inspect.allowed and v_inspect.reason = 'COLONY_CAP_REACHED'
            and v_inspect.current_planets = 2 and v_inspect.max_slots = 2;
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. moon excluded from the count: %s planets of %s -> %s', v_inspect.current_planets, v_inspect.max_slots, v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. the dispatch gate refuses a colonisation fleet at the cap (OGameX ColonyEstablishFailAstrophysics) */
    v_g := (select galaxy from public.planets where id = v_origin);
    v_s := 499; v_p := 15;
    v_raised := null;
    begin
        perform public.start_colonize_fleet(v_player, v_origin, v_g, v_s, v_p);
    exception when others then v_raised := sqlerrm; end;
    v_ok := v_raised like 'COLONY_CAP_REACHED%';
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. dispatch refused at the cap (%s)', coalesce(v_raised, 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. astrophysics lifts the cap again */
    update public.player_research set level = 4 where player_id = v_player and research_id = 'astrophysics';
    select * into v_inspect from public.check_colony_cap(v_player);
    v_ok := v_inspect.allowed and v_inspect.max_slots = 3 and v_inspect.current_planets = 2;
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. astro 4 lifts the cap to %s (%s)', v_inspect.max_slots, v_inspect.reason));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. ACL */
    v_ok := has_function_privilege('authenticated', 'public.check_colony_cap(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.calculate_max_colony_slots(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.check_colony_cap(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.calculate_max_colony_slots(uuid)', 'EXECUTE');
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. ACL: colony cap contracts are authenticated/service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_cc(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness (no concurrency). The creation gate in resolve_colonize_arrival is the defensive one and is asserted by source inspection below.');

    v_ok := (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'resolve_colonize_arrival' and p.prosrc like '%COLONY_CAP_REACHED%') = 1;
    insert into t_cc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. resolve_colonize_arrival carries the creation gate');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    if v_fail > 0 then
        raise exception 'COLONY CAP FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cc order by orden;

drop table if exists t_cc;

ROLLBACK;