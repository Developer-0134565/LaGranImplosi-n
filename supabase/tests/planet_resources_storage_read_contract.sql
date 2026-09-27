-- GAP A — PLANET RESOURCES / STORAGE READ CONTRACT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260926280000_fix_planet_resources_and_storage_read_contract):
--   * public.calculate_planet_storage(uuid) and public.get_current_planet_resources(uuid) are
--     bounded SECURITY DEFINER contracts (owner postgres, pinned search_path) and no longer
--     depend on a client SELECT grant on public.universes;
--   * BEFORE the fix both aborted for any client role with
--         ERROR 42501: permission denied for table universes
--     (calculate_planet_storage line 10: planets JOIN universes;
--      get_current_planet_resources line 40 -> calculate_planet_production -> calculate_universe_rates
--      line 13 -> universes). Both probes were executed LIVE inside a rolled-back authenticated
--     session before the migration; assertion 2/3 below run the fixed versions of the same probes;
--   * owner   -> PASS, with the SAME economic values the certified internal computation produces
--     (storage formula and stored resources compared against an independent expectation);
--   * foreign authenticated actor -> PLAYER_NOT_OWNED and no value is returned;
--   * anon    -> refused by the ACL (no EXECUTE at all, not even the internal 42501);
--   * service/worker context (auth.uid() IS NULL) -> UNCHANGED: it still reads FOREIGN planets,
--     which the fleet, combat, espionage, moon and merchant settlement workers require;
--   * public.universes keeps NO client SELECT grant and calculate_universe_rates stays untouched
--     (the deferred P3 hygiene of the remaining PUBLIC INVOKER helpers is out of this scope).
--
-- LIMITATION: single-session harness with role switching via set_config('role', ...), exactly as
-- the other fixtures of this repository. It writes only tables that
-- enforce_player_write_access does not protect (planet_resources, planet_buildings) and rolls
-- everything back.

begin;

drop table if exists t_gap_a;
create temp table t_gap_a(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid;
    v_foreign_player uuid; v_foreign_planet uuid; v_intruder uuid := gen_random_uuid();
    v_storage record; v_storage_svc record; v_res record; v_res_svc record;
    v_foreign_storage record; v_foreign_res record;
    v_expected_metal numeric; v_expected_crystal numeric; v_expected_deuterium numeric;
    v_multiplier numeric; v_item_bonus numeric;
    v_ok boolean; v_fail integer := 0; v_err text; v_blocked boolean; v_anon_err text;
    v_foreign_err text; v_foreign_blocked boolean;
    v_anon_exec boolean; v_auth_exec boolean; v_svc_exec boolean;
    v_sigs integer; v_def boolean; v_owner text; v_cfg text;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.is_homeworld desc, p.created_at, p.id limit 1;
    select p.player_id, p.id into v_foreign_player, v_foreign_planet
      from public.planets p join public.players pl on pl.id = p.player_id
     where pl.id <> v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_foreign_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    /* ------------------------------------------------------------------ FIXTURE DATA
       Unambiguous values in tables the write-access trigger does not protect. Everything is
       rolled back at the end. */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    update public.planet_resources
       set metal = 12345.5, crystal = 23456.5, deuterium = 34567.5, energy = 456.5
     where planet_id = v_planet;

    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_planet, 'metal_storage', 3),
        (v_planet, 'crystal_storage', 1),
        (v_planet, 'deuterium_tank', 0)
    on conflict (planet_id, building_id) do update set level = excluded.level;

    update public.planet_resources
       set metal = 999999, crystal = 888888, deuterium = 777777
     where planet_id = v_foreign_planet;

    /* the fixture's own storage expectation, with its inputs asserted independently */
    select u.storage_multiplier into v_multiplier
      from public.planets p join public.universes u on u.id = p.universe_id where p.id = v_planet;
    v_item_bonus := public.get_active_expedition_item_effect(v_player, v_planet, 'storage_percent');

    if coalesce(v_multiplier, 0) <> 1 or coalesce(v_item_bonus, 0) <> 0 then
        raise exception 'TEST_ABORT: unexpected storage multiplier (%) or active item effect (%)',
            v_multiplier, v_item_bonus;
    end if;

    v_expected_metal := 100000 * power(2, 3) * v_multiplier;
    v_expected_crystal := 100000 * power(2, 1) * v_multiplier;
    v_expected_deuterium := 100000 * power(2, 0) * v_multiplier;

    /* --------------------------------- 1. OWNER: the storage contract now answers a client */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
    select * into v_storage from public.calculate_planet_storage(v_planet);
    select * into v_res from public.get_current_planet_resources(v_planet);
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '{}', true);

    v_ok := v_storage.metal_capacity = v_expected_metal
        and v_storage.crystal_capacity = v_expected_crystal
        and v_storage.deuterium_capacity = v_expected_deuterium;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. owner calculate_planet_storage as authenticated -> %s / %s / %s (expected %s / %s / %s)',
             v_storage.metal_capacity, v_storage.crystal_capacity, v_storage.deuterium_capacity,
             v_expected_metal, v_expected_crystal, v_expected_deuterium));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------- 2. OWNER: full resource payload, same economic values */
    v_ok := v_res.planet_id = v_planet
        and v_res.metal = 12345.5 and v_res.crystal = 23456.5
        and v_res.deuterium = 34567.5 and v_res.energy = 456.5
        and v_res.elapsed_seconds >= 0
        and v_res.projected_metal between 12345.5 and v_expected_metal
        and v_res.projected_crystal between 23456.5 and v_expected_crystal
        and v_res.projected_deuterium between 34567.5 and v_expected_deuterium;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. owner get_current_planet_resources as authenticated -> stored %s/%s/%s energy %s, projected %s/%s/%s capped by the storage contract',
             v_res.metal, v_res.crystal, v_res.deuterium, v_res.energy,
             v_res.projected_metal, v_res.projected_crystal, v_res.projected_deuterium));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------- 3. THE ECONOMY IS UNCHANGED: definer context parity */
    select * into v_storage_svc from public.calculate_planet_storage(v_planet);
    select * into v_res_svc from public.get_current_planet_resources(v_planet);

    v_ok := v_storage_svc.metal_capacity = v_storage.metal_capacity
        and v_storage_svc.crystal_capacity = v_storage.crystal_capacity
        and v_storage_svc.deuterium_capacity = v_storage.deuterium_capacity
        and v_res_svc.metal = v_res.metal and v_res_svc.crystal = v_res.crystal
        and v_res_svc.deuterium = v_res.deuterium and v_res_svc.energy = v_res.energy
        and v_res_svc.elapsed_seconds = v_res.elapsed_seconds
        and v_res_svc.projected_metal = v_res.projected_metal
        and v_res_svc.projected_crystal = v_res.projected_crystal
        and v_res_svc.projected_deuterium = v_res.projected_deuterium;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. the client answer is byte-identical to the internal (service/owner) computation: no formula, rounding or projection drift');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------- 4. FOREIGN ACTOR: refused on both contracts */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_intruder, 'role', 'authenticated')::text, true);

    v_blocked := false; v_err := null;
    begin
        select * into v_foreign_res from public.get_current_planet_resources(v_foreign_planet);
    exception when others then v_blocked := true; v_err := sqlerrm; end;
    v_foreign_err := v_err;
    v_foreign_blocked := v_blocked;

    v_blocked := false; v_err := null;
    begin
        select * into v_foreign_storage from public.calculate_planet_storage(v_foreign_planet);
    exception when others then v_blocked := true; v_err := sqlerrm; end;

    perform set_config('role', 'postgres', true);

    v_ok := v_foreign_blocked and v_foreign_err = 'PLAYER_NOT_OWNED';
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. foreign actor -> get_current_planet_resources raised %s (the function returns nothing, so no resource value can leak)',
             coalesce(v_foreign_err, '(no error: LEAK)')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := v_blocked and v_err = 'PLAYER_NOT_OWNED';
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. foreign actor -> calculate_planet_storage raised %s (no capacity value returned)',
             coalesce(v_err, '(no error: LEAK)')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------ 6. ANON: refused by the ACL */
    v_anon_exec := has_function_privilege('anon', 'public.calculate_planet_storage(uuid)', 'EXECUTE')
                or has_function_privilege('anon', 'public.get_current_planet_resources(uuid)', 'EXECUTE');

    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', '{}', true);
    v_blocked := false; v_anon_err := null;
    begin
        perform 1 from public.calculate_planet_storage(v_planet);
    exception when others then v_blocked := true; v_anon_err := sqlerrm; end;
    perform set_config('role', 'postgres', true);

    v_ok := v_blocked and not v_anon_exec;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. anonymous actor -> refused (%s) and anon holds EXECUTE = %s', coalesce(v_anon_err, '(no error)'), v_anon_exec));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------- 7. WORKER CONTEXT: foreign planets keep working */
    perform set_config('role', 'service_role', true);
    perform set_config('request.jwt.claims', '{}', true);
    select * into v_foreign_storage from public.calculate_planet_storage(v_foreign_planet);
    select * into v_foreign_res from public.get_current_planet_resources(v_foreign_planet);
    perform set_config('role', 'postgres', true);

    v_ok := v_foreign_res.metal = 999999 and v_foreign_res.crystal = 888888
        and v_foreign_res.deuterium = 777777
        and v_foreign_storage.metal_capacity = 100000;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. service/worker context (auth.uid() IS NULL) still settles a FOREIGN planet -> %s/%s/%s, capacity %s',
             v_foreign_res.metal, v_foreign_res.crystal, v_foreign_res.deuterium,
             v_foreign_storage.metal_capacity));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------- 8. CONTRACT SHAPE + ACL + NOTHING WIDENED */
    v_auth_exec := true; v_svc_exec := true; v_sigs := 0; v_def := true; v_owner := 'postgres'; v_cfg := '';
    for v_anon_err in select unnest(array['calculate_planet_storage','get_current_planet_resources']) loop
        select p.prosecdef, pg_get_userbyid(p.proowner), coalesce(array_to_string(p.proconfig, ','), '')
          into v_def, v_owner, v_cfg
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = v_anon_err
           and pg_get_function_identity_arguments(p.oid) = 'p_planet_id uuid';

        select count(*) into v_sigs from pg_proc p2
         where p2.pronamespace = 'public'::regnamespace and p2.proname = v_anon_err;

        v_auth_exec := v_auth_exec
            and has_function_privilege('authenticated', format('public.%I(uuid)', v_anon_err), 'EXECUTE');
        v_svc_exec := v_svc_exec
            and has_function_privilege('service_role', format('public.%I(uuid)', v_anon_err), 'EXECUTE');

        if not v_def or v_owner <> 'postgres' or v_cfg not like '%search_path=public, pg_temp%'
           or v_sigs <> 1
           or not exists (select 1 from pg_proc p3
                           where p3.pronamespace = 'public'::regnamespace and p3.proname = v_anon_err
                             and p3.prosrc like '%PLAYER_NOT_OWNED%') then
            v_auth_exec := false;
        end if;
    end loop;

    v_ok := v_auth_exec and v_svc_exec;
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. both contracts are SECURITY DEFINER, owned by postgres, single signature, pinned search_path, gated; authenticated=%s service_role=%s',
             v_auth_exec, v_svc_exec));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := not has_table_privilege('anon', 'public.universes', 'SELECT')
        and not has_table_privilege('authenticated', 'public.universes', 'SELECT');
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '9. public.universes still carries NO client SELECT grant (the fix did not open the table)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := exists (select 1 from pg_proc p
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'calculate_universe_rates'
                       and not p.prosecdef);
    insert into t_gap_a(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. calculate_universe_rates is untouched (still INVOKER): the deferred hygiene of the other PUBLIC helpers is out of this scope');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_gap_a(resultado, prueba) values ('INFO',
      'RESIDUAL (documented, not fixed here): calculate_building_time, calculate_ship_build_time, calculate_defense_build_time, calculate_research_time, calculate_lifeform_*_time, calculate_universe_evolution_* and calculate_planet_production stay PUBLIC INVOKER and still hit 42501 on public.universes; no frontend caller invokes them.');

    if v_fail > 0 then
        raise exception 'GAP A FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 and count(*) filter (where resultado = 'PASS') >= 10
            then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) as assertions
  from t_gap_a;

select orden, resultado, prueba from t_gap_a order by orden;

drop table if exists t_gap_a;

rollback;


