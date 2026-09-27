-- UNIVERSE DEBRIS READ CONTRACT — CERTIFICATION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260927035703_universe_debris_read_contract):
--   `get_universe_debris(universe, galaxy, system)` → una fila por campo de restos con `out_position`,
--   `out_metal`, `out_crystal`, `out_updated_at`.
--
-- Por qué existe: `public.debris_fields` lleva la política `deny_direct_api_access` y ningún contrato la
-- exponía, así que la misión RECYCLE (que el servidor dirige al campo MÁS CERCANO) era completamente ciega.
-- El contrato NO abre la tabla: valida la pertenencia al universo con `auth.uid()` → `players.user_id` y
-- expone sólo el sistema consultado. Los caminos de escritura siguen internos.

begin;

drop table if exists t_debris_results;
create temp table t_debris_results(orden serial, resultado text, prueba text);
grant insert, select on t_debris_results to authenticated;
grant usage, select on sequence t_debris_results_orden_seq to authenticated;

drop table if exists t_debris_ids;
create temp table t_debris_ids(universe_id uuid, galaxy integer, system integer);
grant select on t_debris_ids to authenticated;

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_universe uuid;
    v_foreign_universe uuid;
    v_galaxy integer;
    v_system integer;
    v_position integer := 9;
    v_rows integer;
    v_metal numeric;
    v_crystal numeric;
    v_updated timestamp with time zone;
    v_ok boolean;
    v_auth_exec boolean;
    v_anon_exec boolean;
    v_public boolean;
    v_fail integer := 0;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.galaxy, p.system into v_galaxy, v_system
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select u.id into v_foreign_universe from public.universes u where u.id <> v_universe order by u.id limit 1;

    if v_player is null or v_universe is null or v_galaxy is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a universe are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 1. ACL */
    select has_function_privilege('authenticated', 'public.get_universe_debris(uuid, integer, integer)', 'EXECUTE') into v_auth_exec;
    select has_function_privilege('anon', 'public.get_universe_debris(uuid, integer, integer)', 'EXECUTE') into v_anon_exec;
    select exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'get_universe_debris'
           and exists (select 1 from unnest(p.proacl) a where a::text like '=%')
    ) into v_public;
    v_ok := v_auth_exec and not v_anon_exec and not v_public;
    insert into t_debris_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. ACL: authenticated=%s anon=%s PUBLIC=%s', v_auth_exec, v_anon_exec, v_public));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 2. LA TABLA SIGUE CERRADA POR POLÍTICA */
    select exists (
        select 1 from pg_policy pol join pg_class c on c.oid = pol.polrelid
         where c.relname = 'debris_fields' and pol.polname = 'deny_direct_api_access'
    ) into v_ok;
    insert into t_debris_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. debris_fields keeps its deny_direct_api_access policy [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 3. SIN SESIÓN: 0 filas */
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_universe_debris(v_universe, v_galaxy, v_system);
    insert into t_debris_results(resultado, prueba) values (case when v_rows = 0 then 'PASS' else 'FAIL' end,
      format('3. without a session: %s row(s)', v_rows));
    v_fail := v_fail + case when v_rows = 0 then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 4. UNIVERSO AJENO: 0 filas */
    v_rows := 0;
    if v_foreign_universe is not null then
        select count(*)::integer into v_rows from public.get_universe_debris(v_foreign_universe, 1, 1);
    end if;
    insert into t_debris_results(resultado, prueba) values (case when v_rows = 0 then 'PASS' else 'FAIL' end,
      format('4. a foreign universe returns %s row(s)', v_rows));
    v_fail := v_fail + case when v_rows = 0 then 0 else 1 end;

    /* ---------------------- 5. SISTEMA PROPIO CON RESTOS: fila exacta y sólo de ese sistema */
    insert into public.debris_fields(universe_id, galaxy, system, position, metal, crystal)
    values (v_universe, v_galaxy, v_system, v_position, 12345, 6789);

    select count(*)::integer into v_rows from public.get_universe_debris(v_universe, v_galaxy, v_system);
    select out_metal, out_crystal into v_metal, v_crystal
      from public.get_universe_debris(v_universe, v_galaxy, v_system) where out_position = v_position;
    v_ok := v_rows = 1 and v_metal = 12345 and v_crystal = 6789;
    insert into t_debris_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. own system: %s row(s); position %s holds %s M / %s C', v_rows, v_position, v_metal, v_crystal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_rows from public.get_universe_debris(v_universe, v_galaxy, v_system + 1);
    insert into t_debris_results(resultado, prueba) values (case when v_rows = 0 then 'PASS' else 'FAIL' end,
      format('6. another system of the same universe returns %s row(s)', v_rows));
    v_fail := v_fail + case when v_rows = 0 then 0 else 1 end;

    /* ---------------------- 7. UN CAMPO A CERO NO SE ANUNCIA */
    insert into public.debris_fields(universe_id, galaxy, system, position, metal, crystal)
    values (v_universe, v_galaxy, v_system, v_position + 1, 0, 0);
    select count(*)::integer into v_rows from public.get_universe_debris(v_universe, v_galaxy, v_system);
    insert into t_debris_results(resultado, prueba) values (case when v_rows = 1 then 'PASS' else 'FAIL' end,
      format('7. an empty debris field is not announced [rows=%s]', v_rows));
    v_fail := v_fail + case when v_rows = 1 then 0 else 1 end;

    /* ---------------------- 8. PERSISTENCIA: `updated_at` se devuelve tal cual */
    select out_updated_at into v_updated from public.get_universe_debris(v_universe, v_galaxy, v_system) where out_position = v_position;
    v_ok := v_updated is not null;
    insert into t_debris_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. the row carries updated_at [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_debris_ids(universe_id, galaxy, system) values (v_universe, v_galaxy, v_system);
    insert into t_debris_results(resultado, prueba) values ('INFO',
      'LIMITATION: una sola sesión; sólo lectura, sin escrituras que concurrir. Los productores de restos (create_combat_debris / add_debris_field) y el recolector (collect_debris) siguen internos.');

    if v_fail > 0 then
        raise exception 'UNIVERSE DEBRIS FIXTURE (owner session): % failed assertion(s)', v_fail;
    end if;
end;
$test$;

-- ============================================================================================
-- SESIÓN DE CLIENTE REAL (`authenticated`): el contrato funciona y la tabla sigue cerrada.
-- ============================================================================================
set local role authenticated;

do $client$
declare
    v_universe uuid;
    v_galaxy integer;
    v_system integer;
    v_rows integer;
    v_table_rows integer;
    v_fail integer := 0;
begin
    select universe_id, galaxy, system into v_universe, v_galaxy, v_system from t_debris_ids limit 1;

    select count(*)::integer into v_rows from public.get_universe_debris(v_universe, v_galaxy, v_system);
    insert into t_debris_results(resultado, prueba) values (case when v_rows >= 1 then 'PASS' else 'FAIL' end,
      format('9. as authenticated: the contract returns %s row(s) for the own universe', v_rows));
    v_fail := v_fail + case when v_rows >= 1 then 0 else 1 end;

    begin
        select count(*)::integer into v_table_rows from public.debris_fields;
        insert into t_debris_results(resultado, prueba) values (case when v_table_rows = 0 then 'PASS' else 'FAIL' end,
          format('10. as authenticated the debris TABLE is still unreadable [%s row(s)]', v_table_rows));
    exception when others then
        v_table_rows := -1;
        insert into t_debris_results(resultado, prueba) values ('PASS',
          '10. as authenticated the debris TABLE is still unreadable [raised]');
    end;
    v_fail := v_fail + case when v_table_rows <= 0 then 0 else 1 end;

    if v_fail > 0 then
        raise exception 'UNIVERSE DEBRIS FIXTURE (client role): % failed assertion(s)', v_fail;
    end if;
end;
$client$;

reset role;

select orden, resultado, prueba from t_debris_results order by orden;

drop table if exists t_debris_results;
drop table if exists t_debris_ids;

ROLLBACK;
