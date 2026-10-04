-- CRAWLER STATUS READ CONTRACT — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260929040000): `get_planet_crawler_status` exposes the crawler's count,
-- cap, effective count, production bonus and energy draw to the authenticated owner.
--
-- The point of this fixture is that the new contract is NOT a second source of truth. It repeats
-- the expressions of `calculate_planet_production` on purpose (the economy is the certified core
-- and is not modified), so every assertion here that compares the contract against the ECONOMY is
-- what keeps the two from drifting apart. If somebody changes the cap in one place only, the
-- "agrees with the economy" assertions fail.
--
-- LIMITATION: single-session harness with ROLLBACK. Uses the same `request.jwt.claims` mechanism
-- as the other ACL fixtures; no JWT is fabricated and no data is faked. Concurrency is not run.

begin;

drop table if exists t_cs;
create temp table t_cs(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid; v_other_planet uuid;
    v_row record; v_rows integer; v_fail integer := 0; v_ok boolean;
    v_metal0 numeric; v_metal_capped numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;
    /* a genuinely foreign planet (AI owned), not a fabricated one */
    select p.id into v_other_planet
      from public.planets p where p.player_id is distinct from v_player and not p.is_destroyed
      order by p.created_at limit 1;

    if v_player is null or v_planet is null or v_other_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player, its planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------------------------------------------------- 1. ACL */
    v_ok := has_function_privilege('authenticated', 'public.get_planet_crawler_status(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_planet_crawler_status(uuid)', 'EXECUTE')
            and not has_function_privilege('public', 'public.get_planet_crawler_status(uuid)', 'EXECUTE');
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. ACL: authenticated EXECUTE, anon and PUBLIC closed');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------- 2. owner on own planet */
    delete from public.planet_buildings where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_planet, 'metal_mine', 10), (v_planet, 'crystal_mine', 10),
        (v_planet, 'deuterium_synthesizer', 10), (v_planet, 'solar_plant', 60);
    delete from public.planet_ships where planet_id = v_planet;
    update public.planet_resources set metal = 1000000, crystal = 1000000, deuterium = 1000000,
           last_calculated_at = clock_timestamp() where planet_id = v_planet;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'crawler', 100)
    on conflict (planet_id, ship_id) do update set quantity = 100;

    select * into v_row from public.get_planet_crawler_status(v_planet);
    v_ok := v_row.crawler_count = 100
            and v_row.crawler_cap = 240                     -- (10 + 10 + 10) * 8
            and v_row.crawler_effective = 100                -- under the cap
            and v_row.crawler_bonus_percent = 2              -- 0.02 % * 100
            and v_row.crawler_energy_per_hour = 5000;        -- 50 * 100
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. owner reads count/cap/effective/bonus/energy (%s / %s / %s / %s / %s)',
             v_row.crawler_count, v_row.crawler_cap, v_row.crawler_effective,
             v_row.crawler_bonus_percent, v_row.crawler_energy_per_hour));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* -------------------------------------------------------- 3. no session */
    perform set_config('request.jwt.claims', json_build_object('sub', null::text)::text, true);
    select count(*) into v_rows from public.get_planet_crawler_status(v_planet);
    v_ok := v_rows = 0;
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. without a session the contract returns nothing (%s row(s))', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 4. foreign planet */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    select count(*) into v_rows from public.get_planet_crawler_status(v_other_planet);
    v_ok := v_rows = 0;
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. another player''s planet returns nothing, not a value (%s row(s))', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------- 5. unknown planet */
    select count(*) into v_rows
      from public.get_planet_crawler_status('00000000-0000-0000-0000-000000000000'::uuid);
    v_ok := v_rows = 0;
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. an invented uuid returns nothing (%s row(s))', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------------- 6. the cap clamps, and the ECONOMY agrees on 240 */
    delete from public.planet_ships where planet_id = v_planet;
    select pp.metal_per_hour into v_metal0 from public.calculate_planet_production(v_planet) pp;

    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet, 'crawler', 1000)
    on conflict (planet_id, ship_id) do update set quantity = 1000;

    select pp.metal_per_hour into v_metal_capped from public.calculate_planet_production(v_planet) pp;
    select * into v_row from public.get_planet_crawler_status(v_planet);

    /* the economy must behave exactly as if there were 240 effective units (the cap the
       contract reports), not the 1000 the player actually owns */
    v_ok := v_row.crawler_count = 1000
            and v_row.crawler_effective = 240
            and v_row.crawler_bonus_percent = 4.8
            and v_row.crawler_energy_per_hour = 12000
            and abs((v_metal_capped / nullif(v_metal0, 0)) - ((30 * 10 * power(1.1, 10)
                    + floor(30 * 10 * power(1.1, 10) * 0.0002 * 240))
                    / (30 * 10 * power(1.1, 10)))) < 0.0005;
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. 1000 crawlers clamp to 240 and the economy agrees (ratio %s)',
             round(v_metal_capped / nullif(v_metal0, 0), 6)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------- 7. zero crawlers = zero bonus, zero energy */
    delete from public.planet_ships where planet_id = v_planet;
    select * into v_row from public.get_planet_crawler_status(v_planet);
    v_ok := v_row.crawler_count = 0 and v_row.crawler_effective = 0
            and v_row.crawler_bonus_percent = 0 and v_row.crawler_energy_per_hour = 0
            and v_row.crawler_cap = 240;   -- the cap is a property of the mines, not of the fleet
    insert into t_cs(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. with no crawlers the bonus and the energy draw are zero while the cap still exists');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_cs(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. The cap is expressed in mine
       levels exactly as the certified economy does, so this fixture deliberately re-derives it and
       pins it against calculate_planet_production rather than trusting a shared helper.');

    if v_fail > 0 then
        raise exception 'CRAWLER STATUS CONTRACT: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cs order by orden;

drop table if exists t_cs;

ROLLBACK;
