-- ============================================================================
-- RESEARCH LIFECYCLE TEST — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NO ES UNA MIGRACIÓN. Test manual transaccional: todo ocurre dentro de una
-- transacción que termina en ROLLBACK, por lo que NO modifica datos reales.
--
-- Identidad: fija `request.jwt.claims` para simular la sesión ANÓNIMA del frontend
-- (auth.uid() = players.user_id), el mismo contrato que aplica la migración
-- 20260918030000_harden_player_ownership_in_owned_rpcs.sql.
--
-- Cubre 16 bloques: definición válida/inválida · coste · tiempo (+overload) ·
-- prerrequisitos incumplidos/satisfechos · recursos insuficientes · start ·
-- descuento · cola · exclusión de segunda investigación · processing · completion ·
-- persistencia · doble completion (comportamiento REAL, no idempotente) · ownership.
--
-- Bloque final BLIND SPOT / CLIENT CONTRACT (solo lectura, sin gate): reproduce el rol cliente REAL
-- (SET LOCAL ROLE authenticated) para medir el camino cliente de can_research /
-- check_research_requirements sobre `research_prerequisites` (tabla interna con RLS RESTRICTIVE).
-- Si el harness no puede impersonar el rol, la prueba se marca PENDIENTE: nunca se falsea el
-- resultado con privilegios de owner. Detalle: docs/systems/README_RESEARCH.md §1b.
--
-- Ejecutable desde el SQL Editor o mediante execute_sql (MCP). No usa framework externo.
-- ============================================================================

begin;

do $test$
declare
    v_player uuid;
    v_user uuid;
    v_planet uuid;
    v_universe uuid;
    v_research text;
    v_research2 text;
    v_research_pre text;
    v_def record;
    v_level int;
    v_target int;
    v_cost record;
    v_oracle_metal numeric;
    v_oracle_crystal numeric;
    v_oracle_deuterium numeric;
    v_speed numeric;
    v_evo numeric;
    v_time numeric;
    v_time_oracle numeric;
    v_time_overload numeric;
    v_queue uuid;
    v_status text;
    v_target_level int;
    v_started timestamptz;
    v_finishes timestamptz;
    v_queue_planet uuid;
    v_before_metal numeric;
    v_after_metal numeric;
    v_before_crystal numeric;
    v_after_crystal numeric;
    v_before_deut numeric;
    v_after_deut numeric;
    v_before jsonb;
    v_after jsonb;
    v_prev jsonb;
    v_msg text;
    v_ok boolean;
    v_active int;
    v_rows int;
    v_client_research text;
    v_synthetic uuid;
    v_owner_can boolean;
    v_client_can boolean;
    v_owner_reqs bigint;
    v_client_reqs bigint;
    v_role_switched boolean;
    v_role_msg text;
begin
    create temp table t_results(orden serial, prueba text, resultado text) on commit drop;

    /* ---------------------------------------------------------------- FIXTURE
       Identificable y reversible: se elige un jugador invitado con user_id y un
       planeta propio; todo lo que se toca queda dentro de esta transacción. */
    select pl.id, pl.user_id, p.id, p.universe_id
      into v_player, v_user, v_planet, v_universe
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where coalesce(pl.is_guest, false) = true
      and pl.user_id is not null
      and p.is_destroyed = false
    order by p.created_at, p.id
    limit 1;

    if v_planet is null then
        raise exception 'TEST_ABORT: no hay planeta de invitado con user_id';
    end if;

    /* investigación sin prerrequisitos (happy path) */
    select rd.id into v_research
    from public.research_definitions rd
    where not exists (select 1 from public.research_prerequisites rp where rp.research_id = rd.id)
      and (rd.max_level is null or rd.max_level >= 1)
    order by rd.id limit 1;

    /* segunda investigación sin prerrequisitos (para la exclusión de cola) */
    select rd.id into v_research2
    from public.research_definitions rd
    where not exists (select 1 from public.research_prerequisites rp where rp.research_id = rd.id)
      and rd.id <> v_research
    order by rd.id limit 1;

    /* investigación CON prerrequisitos (para las aserciones 6/7) */
    select rp.research_id into v_research_pre
    from public.research_prerequisites rp
    order by rp.research_id limit 1;

    if v_research is null or v_research2 is null or v_research_pre is null then
        raise exception 'TEST_ABORT: definiciones insuficientes (research=% research2=% pre=%)',
            v_research, v_research2, v_research_pre;
    end if;

    perform set_config('request.jwt.claims',
        json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    delete from public.research_queue where player_id = v_player;

    insert into public.player_research(player_id, research_id, level)
    values (v_player, v_research, 0)
    on conflict (player_id, research_id) do update set level = 0;
    insert into public.player_research(player_id, research_id, level)
    values (v_player, v_research2, 0)
    on conflict (player_id, research_id) do update set level = 0;
    insert into public.player_research(player_id, research_id, level)
    values (v_player, v_research_pre, 0)
    on conflict (player_id, research_id) do update set level = 0;

    update public.planet_resources
       set metal = 50000000, crystal = 50000000, deuterium = 50000000,
           last_calculated_at = now(), updated_at = now()
     where planet_id = v_planet;

    select * into v_def from public.research_definitions rd where rd.id = v_research;
    select coalesce(max(level), 0) into v_level
      from public.player_research where player_id = v_player and research_id = v_research;
    v_target := v_level + 1;
    select u.research_speed into v_speed from public.universes u where u.id = v_universe;
    v_evo := public.calculate_universe_evolution_rate(v_universe);

    raise notice 'TEST planet=% player=% uid=% universe=% research=% (nivel %→%) pre=%',
        v_planet, v_player, v_user, v_universe, v_research, v_level, v_target, v_research_pre;

    /* ------------------------------------------------------------------ 1) DEFINICIÓN VÁLIDA */
    insert into t_results(prueba, resultado) values
      ('1. definición válida (nombre y factores de coste/tiempo)',
       case when v_def.id is not null
                 and coalesce(v_def.name, '') <> ''
                 and v_def.cost_factor > 0
                 and coalesce(v_def.time_factor, 0) > 0
                 and v_def.base_research_time_seconds >= 0
            then 'PASS' else 'FAIL' end);

    /* ------------------------------------------------------------- 2) DEFINICIÓN INVÁLIDA */
    select public.can_research(v_player, 'no_such_research', 1) into v_ok;
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, 'no_such_research');
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('2. definición inválida -> can_research=false + start_research RESEARCH_NOT_FOUND',
       case when v_ok = false and v_msg like 'RESEARCH_NOT_FOUND%' then 'PASS'
            else 'FAIL: can_research=' || coalesce(v_ok::text, 'null') || ' error=' || coalesce(nullif(v_msg, ''), '(sin error)') end);

    /* ------------------------------------------- 3) COSTE = base × cost_factor^(n−1) */
    v_oracle_metal := round(v_def.base_metal * power(v_def.cost_factor, v_target - 1), 4);
    v_oracle_crystal := round(v_def.base_crystal * power(v_def.cost_factor, v_target - 1), 4);
    v_oracle_deuterium := round(v_def.base_deuterium * power(v_def.cost_factor, v_target - 1), 4);
    select * into v_cost from public.calculate_research_cost(v_research, v_target);
    insert into t_results(prueba, resultado) values
      ('3. coste del siguiente nivel = base × cost_factor^(n−1)  [' ||
       v_cost.metal || '/' || v_cost.crystal || '/' || v_cost.deuterium || ']',
       case when v_cost.metal = v_oracle_metal
                 and v_cost.crystal = v_oracle_crystal
                 and v_cost.deuterium = v_oracle_deuterium
                 and v_cost.target_level = v_target
            then 'PASS' else 'FAIL: esperado ' || v_oracle_metal || '/' || v_oracle_crystal || '/' || v_oracle_deuterium end);

    /* ------------------- 4) TIEMPO = base × time_factor^(n−1) ÷ (research_speed × √E) */
    v_time := public.calculate_research_time(v_research, v_target, v_universe);
    v_time_oracle := round(
        (v_def.base_research_time_seconds * power(v_def.time_factor, v_target - 1)) / (v_speed * sqrt(v_evo)),
        4);
    insert into t_results(prueba, resultado) values
      ('4. tiempo = base × time_factor^(n−1) ÷ (research_speed × √E)  [' || v_time ||
       ' vs ' || v_time_oracle || ' · speed ' || v_speed || ' · E ' || round(v_evo, 6) || ']',
       case when v_time = v_time_oracle then 'PASS' else 'FAIL' end);

    /* ------------------------------ 5) OVERLOAD ALTERNATIVO (uuid,text,integer) EQUIVALE */
    select t.final_time_seconds into v_time_overload
    from public.calculate_research_time(v_player, v_research, v_target) t;
    insert into t_results(prueba, resultado) values
      ('5. overload calculate_research_time(uuid,text,integer) equivalente al canónico',
       case when v_time_overload = v_time then 'PASS'
            else 'FAIL: overload=' || coalesce(v_time_overload::text, 'null') || ' canonico=' || v_time end);

    /* ------------------------------------------- 6) PRERREQUISITOS INCUMPLIDOS */
    update public.player_research
       set level = 0
     where player_id = v_player
       and research_id in (select rp.prerequisite_research_id
                             from public.research_prerequisites rp
                            where rp.research_id = v_research_pre);
    select coalesce(max(level), 0) into v_level
      from public.player_research where player_id = v_player and research_id = v_research_pre;
    select public.can_research(v_player, v_research_pre, v_level + 1) into v_ok;
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, v_research_pre);
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('6. prerrequisitos incumplidos -> can_research=false + RESEARCH_REQUIREMENTS_NOT_MET  [' || v_research_pre || ']',
       case when v_ok = false and v_msg like 'RESEARCH_REQUIREMENTS_NOT_MET%' then 'PASS'
            else 'FAIL: can_research=' || coalesce(v_ok::text, 'null') || ' error=' || coalesce(nullif(v_msg, ''), '(sin error)') end);

    /* ------------------------------------------- 7) PRERREQUISITOS SATISFECHOS */
    insert into public.player_research(player_id, research_id, level)
    select v_player, rp.prerequisite_research_id, rp.required_level
      from public.research_prerequisites rp
     where rp.research_id = v_research_pre
    on conflict (player_id, research_id) do update set level = excluded.level;
    select public.can_research(v_player, v_research_pre, v_level + 1) into v_ok;
    insert into t_results(prueba, resultado) values
      ('7. prerrequisitos satisfechos -> can_research=true  [' || v_research_pre || ']',
       case when v_ok = true then 'PASS' else 'FAIL: can_research=' || coalesce(v_ok::text, 'null') end);

    /* ------------------------------------------------ 8) RECURSOS INSUFICIENTES */
    update public.planet_resources set metal = 0, crystal = 0, deuterium = 0 where planet_id = v_planet;
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, v_research);
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('8. recursos insuficientes -> rechazado (INSUFFICIENT_RESOURCES)',
       case when v_msg like 'INSUFFICIENT_RESOURCES%' then 'PASS'
            else 'FAIL: ' || coalesce(nullif(v_msg, ''), '(sin error)') end);

    /* ------------------------- 9) SIN COBRO PARCIAL NI COLA TRAS EL RECHAZO */
    select count(*) into v_rows
      from public.research_queue
     where player_id = v_player and upper(status) in ('RESEARCHING', 'QUEUED', 'ACTIVE');
    select count(*) into v_active
      from public.planet_resources
     where planet_id = v_planet and metal = 0 and crystal = 0 and deuterium = 0;
    insert into t_results(prueba, resultado) values
      ('9. sin cobro parcial ni cola tras el rechazo (recursos intactos, 0 colas)',
       case when v_rows = 0 and v_active = 1 then 'PASS'
            else 'FAIL: colas_activas=' || v_rows || ' recursos_intactos=' || v_active end);

    /* ------------------------------------------------- 10) START VÁLIDO (Y 11 DESC. 12 COLA) */
    update public.planet_resources
       set metal = 50000000, crystal = 50000000, deuterium = 50000000,
           last_calculated_at = now(), updated_at = now()
     where planet_id = v_planet;
    /* Se liquida el tick pendiente antes de medir: start_research también llama a
       process_planet_tick, así que medir antes introduciría producción histórica. */
    perform * from public.process_planet_tick(v_planet);
    select metal, crystal, deuterium into v_before_metal, v_before_crystal, v_before_deut
      from public.planet_resources where planet_id = v_planet;

    v_queue := public.start_research(v_player, v_planet, v_research);

    select metal, crystal, deuterium into v_after_metal, v_after_crystal, v_after_deut
      from public.planet_resources where planet_id = v_planet;
    insert into t_results(prueba, resultado) values
      ('10. start_research devuelve id de cola',
       case when v_queue is not null then 'PASS' else 'FAIL' end);
    insert into t_results(prueba, resultado) values
      ('11. descuento exacto del coste (' || v_cost.metal || '/' || v_cost.crystal || '/' || v_cost.deuterium || ')',
       case when v_before_metal - v_after_metal = v_cost.metal
                 and v_before_crystal - v_after_crystal = v_cost.crystal
                 and v_before_deut - v_after_deut = v_cost.deuterium
            then 'PASS'
            else 'FAIL: descontado ' || (v_before_metal - v_after_metal) || '/' ||
                 (v_before_crystal - v_after_crystal) || '/' || (v_before_deut - v_after_deut) end);

    select status, target_level, started_at, finishes_at, planet_id
      into v_status, v_target_level, v_started, v_finishes, v_queue_planet
      from public.research_queue where id = v_queue;
    insert into t_results(prueba, resultado) values
      ('12. cola: RESEARCHING · target ' || coalesce(v_target_level::text, 'null') ||
       ' · planeta ' || case when v_queue_planet = v_planet then 'correcto' else 'DISTINTO' end ||
       ' · finishes_at > started_at',
       case when upper(v_status) = 'RESEARCHING'
                 and v_target_level = v_target
                 and v_queue_planet = v_planet
                 and v_finishes > v_started
            then 'PASS' else 'FAIL: status=' || coalesce(v_status, 'null') end);

    /* ---------------------------- 13) SEGUNDA INVESTIGACIÓN ACTIVA RECHAZADA (14) UNA SOLA COLA */
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, v_research2);
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('13. segunda investigación activa -> rechazada (RESEARCH_QUEUE_ALREADY_ACTIVE)  [' || v_research2 || ']',
       case when v_msg like 'RESEARCH_QUEUE_ALREADY_ACTIVE%' then 'PASS'
            else 'FAIL: ' || coalesce(nullif(v_msg, ''), '(sin error)') end);
    select count(*) into v_active
      from public.research_queue
     where player_id = v_player and upper(status) in ('RESEARCHING', 'QUEUED', 'ACTIVE');
    insert into t_results(prueba, resultado) values
      ('14. exclusión: queda exactamente 1 investigación activa por jugador',
       case when v_active = 1 then 'PASS' else 'FAIL: activas=' || v_active end);

    /* ------------------------------------------------------------- 15) PROCESSING */
    /* Cola adelantada de forma válida: respeta el CHECK (finishes_at >= started_at) y
       mantiene finishes_at >= last_calculated_at (evita INVALID_RESOURCE_TIMESTAMP). */
    update public.research_queue
       set started_at = now() - interval '1 second',
           finishes_at = now()
     where id = v_queue;
    perform * from public.process_research_queue_for_player(v_player);
    select status into v_status from public.research_queue where id = v_queue;
    insert into t_results(prueba, resultado) values
      ('15. processing (process_research_queue_for_player) -> status COMPLETED',
       case when upper(v_status) = 'COMPLETED' then 'PASS'
            else 'FAIL: status=' || coalesce(v_status, 'null') end);

    /* ------------------------------------------------------------- 16) COMPLETION */
    select coalesce(max(level), 0) into v_level
      from public.player_research where player_id = v_player and research_id = v_research;
    insert into t_results(prueba, resultado) values
      ('16. completion: nivel persistido en player_research = ' || v_target,
       case when v_level = v_target then 'PASS' else 'FAIL: nivel ' || v_level end);

    /* ----------------------------------------------------------- 17) PERSISTENCIA */
    select count(*) into v_rows
      from public.player_research where player_id = v_player and research_id = v_research;
    insert into t_results(prueba, resultado) values
      ('17. persistencia: una sola fila (player_id, research_id) con el nivel objetivo',
       case when v_rows = 1 and v_level = v_target then 'PASS'
            else 'FAIL: filas=' || v_rows || ' nivel=' || v_level end);

    /* ------------ 18) DOBLE COMPLETION: comportamiento REAL (NO idempotente como Buildings) */
    v_msg := '';
    begin
        perform public.complete_research(v_queue);
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('18. doble completion -> excepción real: ' || coalesce(nullif(v_msg, ''), '(sin error)'),
       case when v_msg like 'Research queue is not active%' then 'PASS' else 'FAIL' end);

    /* 19) el doble completion no altera el nivel */
    select coalesce(max(level), 0) into v_active
      from public.player_research where player_id = v_player and research_id = v_research;
    insert into t_results(prueba, resultado) values
      ('19. doble completion sin cambio de nivel (sigue ' || v_target || ')',
       case when v_active = v_target then 'PASS' else 'FAIL: nivel ' || v_active end);

    /* 20) cola inexistente */
    v_msg := '';
    begin
        perform public.complete_research(gen_random_uuid());
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('20. cola inexistente -> ' || coalesce(nullif(v_msg, ''), '(sin error)'),
       case when v_msg like 'Research queue does not exist%' then 'PASS' else 'FAIL' end);

    /* ------------------------------------------------------------- 21-24) OWNERSHIP */
    v_before := jsonb_build_object(
        'metal', (select metal from public.planet_resources where planet_id = v_planet),
        'crystal', (select crystal from public.planet_resources where planet_id = v_planet),
        'deuterium', (select deuterium from public.planet_resources where planet_id = v_planet),
        'level', (select coalesce(max(level), 0) from public.player_research
                   where player_id = v_player and research_id = v_research),
        'active_queue', (select count(*) from public.research_queue
                          where player_id = v_player and upper(status) in ('RESEARCHING', 'QUEUED', 'ACTIVE')),
        'queue_rows', (select count(*) from public.research_queue where player_id = v_player),
        'level_rows', (select count(*) from public.player_research where player_id = v_player));

    select (auth.uid() = v_user) into v_ok;
    insert into t_results(prueba, resultado) values
      ('21. ownership: propietario legítimo (auth.uid() = players.user_id) puede investigar',
       case when v_ok = true and v_queue is not null and v_level = v_target then 'PASS'
            else 'FAIL: uid_ok=' || coalesce(v_ok::text, 'null') end);

    /* 22) sesión AJENA sobre el mismo player */
    perform set_config('request.jwt.claims',
        json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, v_research);
    exception when others then v_msg := sqlerrm; end;
    insert into t_results(prueba, resultado) values
      ('22. ownership: sesión ajena rechazada -> ' || coalesce(nullif(v_msg, ''), '(sin error)'),
       case when v_msg like 'Player does not belong to authenticated user%' then 'PASS' else 'FAIL' end);

    /* 23) el rechazo ajeno no deja mutaciones */
    v_after := jsonb_build_object(
        'metal', (select metal from public.planet_resources where planet_id = v_planet),
        'crystal', (select crystal from public.planet_resources where planet_id = v_planet),
        'deuterium', (select deuterium from public.planet_resources where planet_id = v_planet),
        'level', (select coalesce(max(level), 0) from public.player_research
                   where player_id = v_player and research_id = v_research),
        'active_queue', (select count(*) from public.research_queue
                          where player_id = v_player and upper(status) in ('RESEARCHING', 'QUEUED', 'ACTIVE')),
        'queue_rows', (select count(*) from public.research_queue where player_id = v_player),
        'level_rows', (select count(*) from public.player_research where player_id = v_player));
    insert into t_results(prueba, resultado) values
      ('23. ownership: la sesión ajena no muta nada (recursos, nivel, cola)',
       case when v_after = v_before then 'PASS'
            else 'FAIL: antes=' || v_before::text || ' despues=' || v_after::text end);

    /* 24) auth.uid() NULL (sin sesión) */
    perform set_config('request.jwt.claims', '{}', true);
    v_prev := v_after;
    v_msg := '';
    begin
        perform public.start_research(v_player, v_planet, v_research);
    exception when others then v_msg := sqlerrm; end;
    v_after := jsonb_build_object(
        'metal', (select metal from public.planet_resources where planet_id = v_planet),
        'level', (select coalesce(max(level), 0) from public.player_research
                   where player_id = v_player and research_id = v_research),
        'queue_rows', (select count(*) from public.research_queue where player_id = v_player));
    insert into t_results(prueba, resultado) values
      ('24. ownership: auth.uid() NULL rechazado -> ' || coalesce(nullif(v_msg, ''), '(sin error)') || ' (sin mutaciones)',
       case when (select auth.uid()) is null
                 and v_msg like 'Authentication required%'
                 and v_after->>'metal' = v_prev->>'metal'
                 and v_after->>'level' = v_prev->>'level'
                 and v_after->>'queue_rows' = v_prev->>'queue_rows'
            then 'PASS' else 'FAIL' end);

    /* claims restaurados (la transacción se revierte igualmente) */
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    /* ============================================ BLIND SPOT · CLIENT CONTRACT (solo lectura)
       Documenta y DETECTA el defecto de contrato cliente de Research (README_RESEARCH.md §1b):
       `research_prerequisites` es una tabla interna/autoritaria con una política RLS RESTRICTIVE
       `deny_direct_api_access` (USING(false), migración 20260913043259_harden_api_security_and_indexes),
       de modo que anon/authenticated NO leen sus filas (la API responde 200 [] aunque exista el
       GRANT SELECT), mientras que las funciones SECURITY DEFINER (start_research) sí las leen con
       derechos de owner.

       `can_research`, `check_research_requirements` y `get_research_requirements` son SECURITY
       INVOKER → por el camino CLIENTE la tabla se ve vacía y la respuesta es incorrecta
       (can_research = true y listas de requisitos = []). NO es un bypass de gameplay: start_research
       valida los prerrequisitos con derechos de owner antes de cobrar.

       Este bloque NO falsea el resultado con privilegios de owner: reproduce el rol cliente REAL
       cambiando el rol efectivo (`SET LOCAL ROLE authenticated`, que es lo que decide la RLS; cambiar
       solo auth.uid() no la reproduce), compara con el oráculo del camino owner y, si el harness no
       puede impersonar el rol, marca PENDIENTE. Es estrictamente de LECTURA y sus filas van a
       t_client_contract (separadas del gate de las 24 aserciones). */
    create temp table t_client_contract(orden serial, prueba text, resultado text) on commit drop;

    /* Investigación con prerrequisitos + jugador sintético: oráculo determinista (0 niveles ⇒ todos
       los prerrequisitos incumplidos) e independiente del fixture mutable de este test. */
    select rd.id into v_client_research
    from public.research_definitions rd
    where exists (select 1 from public.research_prerequisites rp where rp.research_id = rd.id)
    order by rd.id
    limit 1;

    v_synthetic := gen_random_uuid();

    if v_client_research is null then
        insert into t_client_contract(prueba, resultado) values
          ('B0. investigación con prerrequisitos localizable',
           'PENDIENTE: research_prerequisites no tiene filas');
    else
        /* Oráculo = camino owner (equivale a las funciones DEFINER). Debe ser concluyente:
           requisitos visibles > 0 y can_research = false para un jugador sin niveles. */
        execute format('select public.can_research(%L::uuid, %L, 1)', v_synthetic, v_client_research)
          into v_owner_can;
        execute format('select count(*) from public.check_research_requirements(%L::uuid, %L)', v_synthetic, v_client_research)
          into v_owner_reqs;

        insert into t_client_contract(prueba, resultado) values
          ('B0. oráculo owner [requisitos=' || v_owner_reqs || ' · can_research=' || v_owner_can || ']',
           case when v_owner_reqs > 0 and v_owner_can = false then 'ORACLE OK'
                else 'PENDIENTE: el oráculo owner no es concluyente' end);

        /* claims de la sesión anónima del frontend (auth.uid() = fixture); el rol se cambia aparte. */
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

        v_role_switched := false;
        v_client_can := null;
        v_client_reqs := null;
        v_role_msg := '';
        begin
            execute 'set local role authenticated';
            v_role_switched := true;
            execute format('select public.can_research(%L::uuid, %L, 1)', v_synthetic, v_client_research)
              into v_client_can;
            execute format('select count(*) from public.check_research_requirements(%L::uuid, %L)', v_synthetic, v_client_research)
              into v_client_reqs;
            execute 'reset role';
        exception when others then
            v_role_msg := sqlerrm;
            begin execute 'reset role'; exception when others then null; end;
        end;

        if not v_role_switched then
            insert into t_client_contract(prueba, resultado) values
              ('B1. rol cliente real (SET LOCAL ROLE authenticated)',
               'PENDIENTE: el harness no puede impersonar el rol cliente -> ' || v_role_msg);
        elsif v_client_can is null or v_client_reqs is null then
            insert into t_client_contract(prueba, resultado) values
              ('B1. camino cliente ejecutable sobre research_prerequisites',
               'PENDIENTE: la comprobación cliente no se completó -> ' || v_role_msg);
        else
            insert into t_client_contract(prueba, resultado) values
              ('B1. camino cliente [can_research=' || v_client_can || ' (owner ' || v_owner_can ||
               ') · requisitos=' || v_client_reqs || ' (owner ' || v_owner_reqs || ')]',
               case when v_client_can = v_owner_can and v_client_reqs = v_owner_reqs
                    then 'PASS: contrato cliente consistente con el oráculo owner'
                    else 'DEFECT (conocido §1b): el camino cliente no coincide con el oráculo; no es bypass de gameplay' end);
        end if;
    end if;

    /* claims restaurados al fixture (la transacción se revierte igualmente) */
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    /* ---------------------------------------------------------------- RESULTADOS */
    raise notice '----- RESEARCH LIFECYCLE TEST -----';
    for v_status, v_research2 in
        select resultado, prueba from t_results order by orden
    loop
        raise notice '%  %', v_status, v_research2;
    end loop;

    select count(*) into v_rows from t_results where resultado <> 'PASS';
    if v_rows > 0 then
        raise exception 'RESEARCH TEST FAILED: % prueba(s) con FAIL', v_rows;
    end if;
    raise notice 'RESEARCH LIFECYCLE TEST: ALL PASS (transacción revertida, sin cambios reales)';
    raise notice 'BLIND SPOT (client contract): ver t_client_contract · docs/systems/README_RESEARCH.md §1b';
end;
$test$;

select orden, resultado, prueba from t_results order by orden;

/* BLIND SPOT / CLIENT CONTRACT — filas informativas, NO forman parte de las 24 aserciones gateadas */
select orden, resultado, prueba from t_client_contract order by orden;

-- ============================================================================
-- RESEARCH AVAILABILITY / OWNERSHIP CONTRACT SUITE (merged from origin/main;
-- client-path assertions run as role authenticated and are read-only).
-- The lifecycle suite above leaves request.jwt.claims set for its own fixture, so
-- the claims are cleared here: the contract suite resolves auth.uid() from
-- request.jwt.claim.sub and must be able to make it NULL (assertion 12).
-- ============================================================================

select set_config('request.jwt.claims', '{}', true);

-- Research lifecycle / availability contract regression tests.
-- All assertions are read-only and run inside a transaction that is rolled back.
-- Client-path checks use role authenticated with a real players.user_id claim.


CREATE TEMP TABLE _research_fixture(
  player_id uuid,
  planet_id uuid,
  user_id uuid,
  research_id text,
  prereq_count integer,
  other_player uuid,
  other_planet uuid
) ON COMMIT DROP;

INSERT INTO _research_fixture
SELECT
  p.id,
  pl.id,
  p.user_id,
  (
    SELECT rp.research_id
    FROM public.research_prerequisites rp
    GROUP BY rp.research_id
    ORDER BY count(*) DESC, rp.research_id
    LIMIT 1
  ),
  (
    SELECT count(*)
    FROM public.research_prerequisites rp2
    WHERE rp2.research_id = (
      SELECT rp.research_id
      FROM public.research_prerequisites rp
      GROUP BY rp.research_id
      ORDER BY count(*) DESC, rp.research_id
      LIMIT 1
    )
  ),
  (SELECT p2.id FROM public.players p2 WHERE p2.id <> p.id LIMIT 1),
  (
    SELECT pl2.id
    FROM public.planets pl2
    WHERE pl2.player_id = (
      SELECT p2.id FROM public.players p2 WHERE p2.id <> p.id LIMIT 1
    )
      AND pl2.is_destroyed = false
    LIMIT 1
  )
FROM public.players p
JOIN public.planets pl
  ON pl.player_id = p.id
 AND pl.is_destroyed = false
WHERE p.user_id IS NOT NULL
LIMIT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _research_fixture) THEN
    RAISE EXCEPTION 'RESEARCH_TEST_FIXTURE_NOT_FOUND';
  END IF;
END $$;

CREATE TEMP TABLE _research_results(
  assertion integer,
  name text,
  pass boolean
) ON COMMIT DROP;

GRANT SELECT, INSERT ON _research_fixture TO authenticated;
GRANT SELECT, INSERT ON _research_results TO authenticated;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM _research_fixture),
  true
);

SET LOCAL ROLE authenticated;

DO $$
DECLARE
  f record;
  r record;
  before_resources jsonb;
  after_resources jsonb;
  before_level integer;
  after_level integer;
  before_queue integer;
  after_queue integer;
BEGIN
  SELECT * INTO f FROM _research_fixture;

  -- 1. Owner can reach the contract and gets a structured result.
  SELECT * INTO r
  FROM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (1, 'owner contract returns result', r.reason_code IS NOT NULL);

  -- 2. Target level is derived by the server.
  INSERT INTO _research_results VALUES
    (2, 'target_level = current_level + 1', r.target_level = r.current_level + 1);

  -- 3. Protected prerequisites are visible to the DEFINER contract.
  INSERT INTO _research_results VALUES
    (3, 'prerequisite detail count', jsonb_array_length(r.prerequisites) = f.prereq_count);

  -- 4. An authenticated owner is not rejected as PLAYER_NOT_OWNED.
  INSERT INTO _research_results VALUES
    (4, 'owner passes ownership gate', r.reason_code <> 'PLAYER_NOT_OWNED');

  -- 5. The new contract is authenticated-only.
  INSERT INTO _research_results VALUES
    (5, 'can_start_research grant boundary',
      has_function_privilege('authenticated','public.can_start_research(uuid,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon','public.can_start_research(uuid,uuid,text)','EXECUTE'));

  -- 6. Legacy helper APIs are closed to the client.
  INSERT INTO _research_results VALUES
    (6, 'legacy research helper APIs closed',
      NOT has_function_privilege('authenticated','public.check_research_requirements(uuid,text)','EXECUTE')
      AND NOT has_function_privilege('authenticated','public.get_research_requirements(uuid,text)','EXECUTE'));

  -- 7. can_research is now an internal helper, not a public API.
  INSERT INTO _research_results VALUES
    (7, 'can_research closed to client',
      NOT has_function_privilege('authenticated','public.can_research(uuid,text,integer)','EXECUTE'));

  -- 8-10. The availability contract is read-only.
  SELECT jsonb_build_object(
           'metal', metal, 'crystal', crystal, 'deuterium', deuterium
         )
  INTO before_resources
  FROM public.planet_resources
  WHERE planet_id = f.planet_id;

  SELECT level INTO before_level
  FROM public.player_research
  WHERE player_id = f.player_id
    AND research_id = f.research_id;

  SELECT count(*) INTO before_queue
  FROM public.research_queue
  WHERE player_id = f.player_id;

  PERFORM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  SELECT jsonb_build_object(
           'metal', metal, 'crystal', crystal, 'deuterium', deuterium
         )
  INTO after_resources
  FROM public.planet_resources
  WHERE planet_id = f.planet_id;

  SELECT level INTO after_level
  FROM public.player_research
  WHERE player_id = f.player_id
    AND research_id = f.research_id;

  SELECT count(*) INTO after_queue
  FROM public.research_queue
  WHERE player_id = f.player_id;

  INSERT INTO _research_results VALUES
    (8, 'resources unchanged', before_resources IS NOT DISTINCT FROM after_resources),
    (9, 'research level unchanged', before_level IS NOT DISTINCT FROM after_level),
    (10, 'queue unchanged', before_queue = after_queue);

  -- 11. Cross-player access is rejected before returning another player's data.
  SELECT * INTO r
  FROM public.can_start_research(f.other_player, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (11, 'foreign player rejected', r.reason_code = 'PLAYER_NOT_OWNED');

  -- 12. Missing auth is rejected before any protected data is returned.
  PERFORM set_config('request.jwt.claim.sub', null, true);

  SELECT * INTO r
  FROM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (12, 'null auth rejected', r.reason_code = 'AUTHENTICATION_REQUIRED');
END $$;

RESET ROLE;

SELECT assertion, name, pass
FROM _research_results
ORDER BY assertion;

DO $$
DECLARE
  failures integer;
BEGIN
  SELECT count(*) INTO failures
  FROM _research_results
  WHERE NOT pass;

  IF failures <> 0 THEN
    RAISE EXCEPTION 'RESEARCH CONTRACT TEST FAILED: % assertion(s)', failures;
  END IF;
END $$;

rollback;
