-- PLANET ECONOMY / BUILD TIME READ CONTRACTS — CERTIFICATION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260927035324_planet_economy_read_contracts):
--   * `get_planet_economy_overview(planet)` — producción/h, balance de energía/h y capacidades de almacén del
--     PROPIO planeta (delega en `calculate_planet_production` / `calculate_planet_energy_balance` /
--     `calculate_planet_storage`);
--   * `get_planet_building_preview(planet)` — por definición: nivel actual, nivel objetivo (el del oráculo
--     certificado `evaluate_building_start_internal`), duración REAL de la obra (misma composición que cobra
--     `start_building`, incluido el bonus de objeto de expedición) y delta de energía/h.
--
-- Por qué existen: esos helpers son SECURITY INVOKER y leen `public.universes`, que NO tiene grant de tabla
-- para el cliente (`permission denied for table universes`, medido LIVE 2026-09-27). Consecuencia real: la
-- vista de Edificios sólo podía mostrar el TIEMPO BASE de la definición y el jugador nunca veía producción,
-- energía ni almacén. Los contratos son DEFINER y **no abren `universes`**: esta fixture lo comprueba.
--
-- Se certifica además que los contratos NO son una segunda fuente de verdad: sus valores se comparan
-- exactamente con los helpers certificados y con el oráculo de disponibilidad, y se comprueba el guard de
-- propiedad (planeta ajeno → 0 filas y NUNCA una excepción ni datos de otro jugador).

begin;

drop table if exists t_econ_results;
create temp table t_econ_results(orden serial, resultado text, prueba text);
grant insert, select on t_econ_results to authenticated;
grant usage, select on sequence t_econ_results_orden_seq to authenticated;

drop table if exists t_econ_ids;
create temp table t_econ_ids(planet_id uuid, foreign_planet_id uuid);
grant select on t_econ_ids to authenticated;

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_planet uuid;
    v_universe uuid;
    v_foreign_planet uuid;
    v_ok boolean;
    v_blocked boolean;
    v_err text;
    v_rows integer;
    v_preview integer;
    v_defs integer;
    v_before numeric;
    v_after numeric;
    v_auth_exec boolean;
    v_anon_exec boolean;
    v_public boolean;
    v_fail integer := 0;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id, p.universe_id into v_planet, v_universe
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select p.id into v_foreign_planet
      from public.planets p
     where p.player_id <> v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_foreign_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    select count(*)::integer into v_defs from public.building_definitions;

    /* ---------------------- 1. ACL */
    select has_function_privilege('authenticated', 'public.get_planet_economy_overview(uuid)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.get_planet_building_preview(uuid)', 'EXECUTE')
      into v_auth_exec;
    select has_function_privilege('anon', 'public.get_planet_economy_overview(uuid)', 'EXECUTE')
        or has_function_privilege('anon', 'public.get_planet_building_preview(uuid)', 'EXECUTE')
      into v_anon_exec;
    select exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('get_planet_economy_overview', 'get_planet_building_preview')
           and exists (select 1 from unnest(p.proacl) a where a::text like '=%')
    ) into v_public;

    v_ok := v_auth_exec and not v_anon_exec and not v_public;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. ACL: authenticated=%s anon=%s PUBLIC=%s', v_auth_exec, v_anon_exec, v_public));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 2. SIN SESIÓN: 0 filas, sin excepción */
    perform set_config('request.jwt.claims', '{}', true);

    select count(*)::integer into v_rows from public.get_planet_economy_overview(v_planet);
    select count(*)::integer into v_preview from public.get_planet_building_preview(v_planet);

    v_ok := v_rows = 0 and v_preview = 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. without a session: economy=%s row(s), preview=%s row(s)', v_rows, v_preview));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 3/4. PLANETA PROPIO: una fila de economía, una fila por definición */
    select count(*)::integer into v_rows from public.get_planet_economy_overview(v_planet);
    v_ok := v_rows = 1;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. own planet: economy returns exactly %s row(s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_preview from public.get_planet_building_preview(v_planet);
    v_ok := v_preview = v_defs and v_defs > 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. own planet: preview returns %s row(s) for %s definitions', v_preview, v_defs));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 5/6/7. LOS VALORES SON LOS DE LOS HELPERS CERTIFICADOS (ni una fórmula nueva) */
    select bool_and(o.metal_per_hour = p.metal_per_hour
                and o.crystal_per_hour = p.crystal_per_hour
                and o.deuterium_per_hour = p.deuterium_per_hour
                and o.energy_per_hour = p.energy_per_hour)
      into v_ok
      from public.get_planet_economy_overview(v_planet) o,
           public.calculate_planet_production(v_planet) p;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. production per hour == calculate_planet_production [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select bool_and(o.energy_production_per_hour = b.energy_production_per_hour
                and o.energy_consumption_per_hour = b.energy_consumption_per_hour
                and o.energy_balance_per_hour = b.energy_balance_per_hour)
      into v_ok
      from public.get_planet_economy_overview(v_planet) o,
           public.calculate_planet_energy_balance(v_planet) b;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. energy per hour == calculate_planet_energy_balance [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select bool_and(o.metal_capacity = s.metal_capacity
                and o.crystal_capacity = s.crystal_capacity
                and o.deuterium_capacity = s.deuterium_capacity)
      into v_ok
      from public.get_planet_economy_overview(v_planet) o,
           public.calculate_planet_storage(v_planet) s;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. storage capacities == calculate_planet_storage [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 8. DURACIÓN == COMPOSICIÓN AUTORITATIVA (idéntica a la que cobra start_building) */
    select bool_and(preview.duration_seconds = round(
               public.calculate_building_time(preview.building_id, preview.target_level, v_universe)
               / (1 + coalesce(public.get_active_expedition_item_effect(v_player, v_planet, 'building_speed_percent'), 0) / 100)
           , 4))
      into v_ok
      from public.get_planet_building_preview(v_planet) preview;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. every duration equals the certified composition incl. item bonus [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 9. NIVEL OBJETIVO == ORÁCULO CERTIFICADO DE DISPONIBILIDAD */
    select bool_and(preview.target_level = oracle.target_level)
      into v_ok
      from public.get_planet_building_preview(v_planet) preview
      join lateral public.can_start_building(v_player, v_planet, preview.building_id) oracle on true;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. target_level agrees with can_start_building for every building [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 10. ENERGÍA == HELPER CERTIFICADO */
    select bool_and(preview.energy_delta_per_hour is not distinct from delta.energy_delta_per_hour)
      into v_ok
      from public.get_planet_building_preview(v_planet) preview
      left join lateral public.calculate_building_energy_delta(v_planet, preview.building_id) delta on true;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. energy delta agrees with calculate_building_energy_delta [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 11. BONUS DE OBJETO DE EXPEDICIÓN: la previsión lo honra igual que la obra real */
    select min(duration_seconds) into v_before from public.get_planet_building_preview(v_planet);

    insert into public.expedition_item_uses(player_id, item_id, planet_id, quantity, effect_snapshot, used_at)
    values (v_player, 'building_boost_10', v_planet, 1,
            jsonb_build_object('effect_key', 'building_speed_percent', 'effect_value', 10,
                               'expires_at', to_jsonb(now() + interval '1 hour')),
            now());

    select min(duration_seconds) into v_after from public.get_planet_building_preview(v_planet);

    select bool_and(preview.duration_seconds = round(
               public.calculate_building_time(preview.building_id, preview.target_level, v_universe)
               / (1 + coalesce(public.get_active_expedition_item_effect(v_player, v_planet, 'building_speed_percent'), 0) / 100)
           , 4))
      into v_ok
      from public.get_planet_building_preview(v_planet) preview;

    v_ok := v_ok and v_after < v_before;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. with an active building_speed_percent item the preview shrinks and still matches the composition [%s -> %s, match=%s]',
             v_before, v_after, v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    delete from public.expedition_item_uses where player_id = v_player and item_id = 'building_boost_10';

    /* ---------------------- 12. PLANETA AJENO CON SESIÓN PROPIA: 0 filas, sin excepción y sin filtración */
    select count(*)::integer into v_rows from public.get_planet_economy_overview(v_foreign_planet);
    select count(*)::integer into v_preview from public.get_planet_building_preview(v_foreign_planet);
    v_ok := v_rows = 0 and v_preview = 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. a foreign planet returns %s economy row(s) and %s preview row(s) — no raise, no leak', v_rows, v_preview));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_econ_ids(planet_id, foreign_planet_id) values (v_planet, v_foreign_planet);
    insert into t_econ_results(resultado, prueba) values ('INFO',
      'LIMITATION: una sola sesión. La concurrencia no se ejecuta; estos contratos son lecturas STABLE sin escrituras.');

    if v_fail > 0 then
        raise exception 'PLANET ECONOMY FIXTURE (owner session): % failed assertion(s)', v_fail;
    end if;
end;
$test$;

-- ============================================================================================
-- SESIÓN DE CLIENTE REAL (`authenticated`): lo que el navegador puede hacer HOY con estos contratos.
-- Los claims JWT siguen puestos (transaction-local) y `set local role` es lo que decide la RLS/grants.
-- ============================================================================================
set local role authenticated;

do $client$
declare
    v_planet uuid;
    v_foreign uuid;
    v_rows integer;
    v_preview integer;
    v_blocked boolean;
    v_err text;
    v_ok boolean;
    v_fail integer := 0;
begin
    select planet_id, foreign_planet_id into v_planet, v_foreign from t_econ_ids limit 1;

    select count(*)::integer into v_rows from public.get_planet_economy_overview(v_planet);
    select count(*)::integer into v_preview from public.get_planet_building_preview(v_planet);
    v_ok := v_rows = 1 and v_preview > 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. as authenticated: own planet gives economy=%s row(s) and preview=%s row(s)', v_rows, v_preview));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_blocked := false; v_err := null;
    begin
        perform 1 from public.calculate_planet_production(v_planet);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and position('permission denied for table universes' in v_err) > 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14a. calculate_planet_production stays unreachable for the client [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_blocked := false; v_err := null;
    begin
        perform 1 from public.calculate_building_time('metal_mine', 5, 'cf021ece-f931-4b9d-ad97-8d0054f371e3');
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and position('permission denied for table universes' in v_err) > 0;
    insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14b. calculate_building_time stays unreachable for the client [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    begin
        select count(*)::integer into v_rows from public.get_planet_economy_overview(v_foreign);
        select count(*)::integer into v_preview from public.get_planet_building_preview(v_foreign);
        v_ok := v_rows = 0 and v_preview = 0;
        insert into t_econ_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('15. as authenticated, a foreign planet gives %s/%s row(s) with no exception', v_rows, v_preview));
    exception when others then
        insert into t_econ_results(resultado, prueba) values ('FAIL',
          '15. as authenticated, a foreign planet RAISED: ' || sqlerrm);
        v_ok := false;
    end;
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_econ_results(resultado, prueba) values ('INFO',
      'SCOPE: the contracts expose ONLY the own planet. Universe rates (get_planet_economic_rates, still blocked for the client) and the projection helpers README_ECONOMY forbids wiring stay out of the browser surface.');

    if v_fail > 0 then
        raise exception 'PLANET ECONOMY FIXTURE (client role): % failed assertion(s)', v_fail;
    end if;
end;
$client$;

reset role;

select orden, resultado, prueba from t_econ_results order by orden;

drop table if exists t_econ_results;
drop table if exists t_econ_ids;

ROLLBACK;
