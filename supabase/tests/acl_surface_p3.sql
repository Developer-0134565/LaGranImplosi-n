-- P3 ACL SURFACE FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260926299000_acl_p3_anon_execute_and_engine_views):
--   1. `authenticated` KEEPS EXECUTE on every client RPC (the allow-list is the `supabase.rpc('…')` inventory of
--      `src/**`), so no UI flow can break.
--   2. `anon` LOST EXECUTE on the internal functions that have no client caller.
--   3. the UI dispatchers keep `authenticated` (App.tsx calls them as a signed-in user).
--   4. the internal AI-engine views are readable by nobody but the definer/owner.
--   5. a NEW function created by the migration role is not born anon-executable (default privileges).
--   6. previously hardened surfaces are untouched by this pass.
--   7. the AI engine still runs after the ACL change.
--   8b. (2026-09-27) the twelve audited SECURITY INVOKER helpers are engine-only: `authenticated` was revoked by
--        `20260927130100`, `anon` was already denied and `service_role` keeps access, while the working siblings
--        (`calculate_planet_production_snapshot`, `calculate_building_cost`, …) keep `authenticated`.
--   8c. (2026-09-27) the four DEAD client-reachable helpers (`get_planet_economic_rates`, `get_planet_rate_snapshot`,
--        `project_planet_resources`, `evaluate_action_at_time`) are engine-only too — every client call could only
--        return a permission error and no caller exists (migration `20260927140000`). Every contract the UI actually
--        calls, including the variable-dispatched `start_building`/`start_research`/`start_ship`/`start_defense` and
--        the four `ui_*_definitions` readers, keeps `authenticated`.
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_p3;
create temp table t_p3(orden serial, resultado text, prueba text);

do $test$
declare
    v_ui text[] := array[
        'can_build_defense', 'can_build_ship', 'can_start_building', 'can_start_demolition',
        'can_start_research', 'check_colony_cap', 'execute_jump_gate', 'get_player_battle_reports',
        'get_player_espionage_reports', 'get_player_expedition_reports', 'get_player_expedition_slot_status',
        'get_player_fleet_slots', 'get_player_messages', 'get_player_moons', 'get_player_support_authorizations',
        'get_universe_evolution_monitor_public', 'get_universe_ranking_by_category',
        'grant_planet_support_authorization', 'load_fleet_cargo', 'mark_message_read', 'provision_player',
        'recall_fleet', 'revoke_planet_support_authorization', 'scan_with_phalanx', 'start_colonize_fleet',
        'start_demolition', 'start_fleet', 'start_fleet_mixed', 'start_moon_destruction', 'start_support_fleet',
        'sync_current_planet_resources', 'use_expedition_item'
    ];
    v_internal text[] := array[
        /* The contracts the UI really calls (re-derived 2026-09-27 from EVERY `supabase.rpc(...)` call site,
           including the `start_building`/`start_research`/`start_ship`/`start_defense` dispatches selected through
           a variable in App.tsx). The previous list wrongly contained engine helpers the UI never calls
           (`calculate_building_cost`, `calculate_research_cost`, `get_planet_economic_rates`,
           `project_planet_resources`, `evaluate_action_at_time`, `on_combat_battle_finished_wreck_field`). */
        'start_building', 'start_research', 'start_ship', 'start_defense',
        'cancel_building', 'cancel_research',
        'get_planet_economy_overview', 'get_planet_building_preview',
        'ui_building_definitions', 'ui_research_definitions', 'ui_ship_definitions', 'ui_defense_definitions'
    ];
    v_views text[] := array[
        'action_candidates', 'action_economic_evaluation', 'action_energy_evaluation',
        'building_action_candidates', 'economic_action_candidates', 'empire_action_ranking',
        'empire_economic_monitor', 'empire_energy_monitor', 'empire_next_action',
        'executable_action_candidates', 'executable_optimization_candidates', 'next_action',
        'next_action_explained', 'normalized_action_candidates', 'optimization_candidates',
        'production_roi_candidates', 'research_action_candidates', 'scored_action_candidates',
        'simulated_followup_actions', 'temporal_action_candidates', 'unified_action_candidates'
    ];
    v_ok boolean; v_fail integer := 0; v_cnt integer; v_expected integer; v_ai uuid; v_date date; v_prof record; v_fn text;
begin
    /* 1. every client RPC still has EXECUTE for `authenticated` */
    v_expected := (select count(distinct u.name) from unnest(v_ui) u(name)
                     join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace);
    v_cnt := (select count(distinct u.name) from unnest(v_ui) u(name)
                join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace
                              and has_function_privilege('authenticated', p.oid, 'EXECUTE'));
    v_ok := v_expected >= 30 and v_cnt = v_expected;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. all %s client RPCs (of %s names in the inventory) keep EXECUTE for authenticated', v_cnt, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 2. the internal functions lost EXECUTE for `anon` */
    v_cnt := (select count(*) from unnest(v_internal) u(name)
                join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace
               where not has_function_privilege('anon', p.oid, 'EXECUTE'));
    v_ok := v_cnt = (select count(*) from unnest(v_internal) u(name)
                       join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace);
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. %s internal functions are no longer anon-executable', v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 3. the UI dispatchers keep `authenticated` */
    v_ok := has_function_privilege('authenticated', 'public.start_building(uuid,uuid,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_defense(uuid,uuid,text,bigint)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_research(uuid,uuid,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.sync_current_planet_resources(uuid,uuid,timestamp with time zone)', 'EXECUTE');
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. UI dispatchers (start_building / start_defense / start_research / sync_current_planet_resources) stay available to authenticated');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 4. the internal AI-engine views: no client access, owner access intact */
    v_cnt := (select count(*) from unnest(v_views) v(name)
                join pg_class c on c.relname = v.name and c.relnamespace = 'public'::regnamespace
               where has_table_privilege('anon', c.oid, 'SELECT') or has_table_privilege('authenticated', c.oid, 'SELECT'));
    v_expected := (select count(*) from unnest(v_views) v(name)
                     join pg_class c on c.relname = v.name and c.relnamespace = 'public'::regnamespace);
    v_ok := v_cnt = 0 and v_expected = 21
            and (select count(*) from unnest(v_views) v(name)
                   join pg_class c on c.relname = v.name and c.relnamespace = 'public'::regnamespace
                  where has_table_privilege('service_role', c.oid, 'SELECT')) = 21;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. %s internal engine views: %s readable by anon/authenticated, 21 readable by service_role', v_expected, v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 5. a NEW function is born service_role-only: the event trigger closes the implicit PUBLIC grant, which
       `ALTER DEFAULT PRIVILEGES … REVOKE … FROM PUBLIC` cannot remove (measured LIVE) */
    create function public.tmp_acl_probe() returns integer language sql as $probe$ select 1 $probe$;
    v_ok := not has_function_privilege('anon', 'public.tmp_acl_probe()', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.tmp_acl_probe()', 'EXECUTE')
            and has_function_privilege('service_role', 'public.tmp_acl_probe()', 'EXECUTE')
            and exists (select 1 from pg_event_trigger e
                         where e.evtname = 'trg_guard_new_function_public_execute' and e.evtenabled <> 'D');
    drop function public.tmp_acl_probe();
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. a new function is born service_role-only (event trigger on CREATE FUNCTION)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 6. previously hardened surfaces are untouched */
    v_ok := not has_function_privilege('authenticated', 'public.ai_decide_and_act(uuid,numeric,timestamp with time zone)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.ai_decide_and_act(uuid,numeric,timestamp with time zone)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.normalize_existing_ai_empires(uuid,integer,boolean)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.start_fleet(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.start_fleet(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE')
            and (select count(*) from pg_policy pol where pol.polrelid = 'public.espionage_reports'::regclass) = 1;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. AI policy/backfill stay service_role-only, espionage reader stays authenticated-only, start_fleet unchanged, RLS policy intact');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 7. the AI engine still runs after the ACL change */
    select pl.id into v_ai from public.players pl
      join public.universes u on u.id = pl.universe_id and u.is_active
     where pl.player_type = 'AI' and pl.user_id is null order by pl.created_at, pl.id limit 1;
    v_date := (now() at time zone 'utc')::date;
    select * into v_prof from public.ai_ensure_player_profile(v_ai);
    v_ok := (select count(*) from public.ai_daily_activity(v_ai, v_date)) > 0
            and v_prof.personality is not null
            and (select count(*) from public.ai_player_profiles where player_id = v_ai) = 1;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. AI engine smoke after the ACL change: daily activity schedule and profile resolution still work');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8. the PUBLIC closure at object level: nothing outside the client allow-list is anonymous-reachable and no
       function keeps an ACL-level PUBLIC grant any more, while `authenticated` keeps exactly what it needs.
       NOTE 2026-09-27: `20260927130100` revoked `authenticated` on the twelve audited SECURITY INVOKER helpers that
       `20260926300000` had re-granted when PUBLIC was their only source (count 121 -> 109), and `20260927140000`
       revoked four more dead client-reachable helpers (109 -> 105). Assertions 8b/8c pin both lists. */
    v_cnt := (select count(*) from pg_proc p
               where p.pronamespace = 'public'::regnamespace
                 and has_function_privilege('anon', p.oid, 'EXECUTE')
                 and not (p.proname = any (v_ui)));
    v_expected := (select count(*) from pg_proc p
                    where p.pronamespace = 'public'::regnamespace
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                      and not (p.proname = any (v_ui)));
    v_ok := v_cnt = 0 and v_expected >= 105
            and has_function_privilege('authenticated', 'public.calculate_building_cost(text,integer)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_planet_economy_overview(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.ui_building_definitions()', 'EXECUTE');
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. anon-reachable outside the client allow-list: %s; authenticated keeps its %s (explicit grants where PUBLIC was the only source)', v_cnt, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8b. the audited INVOKER helpers are engine-only: 20260927130100 revoked `authenticated` on exactly this list
        after the audit proved every one of them fails for a client (they are INVOKER over `universes`, which has no
        client grant) and that no frontend/worker caller exists. They keep `service_role`. */
    v_ok := true;
    foreach v_fn in array array[
        'public.calculate_building_time(text,integer,uuid)',
        'public.calculate_ship_build_time(uuid,text)',
        'public.calculate_defense_build_time(uuid,text)',
        'public.calculate_research_time(uuid,text,integer)',
        'public.calculate_research_time(text,integer,uuid)',
        'public.calculate_lifeform_building_time(uuid,text,integer)',
        'public.calculate_lifeform_research_time(uuid,text,integer)',
        'public.calculate_universe_evolution_population_seconds(uuid,timestamp with time zone,timestamp with time zone)',
        'public.calculate_universe_evolution_production_seconds(uuid,timestamp with time zone,timestamp with time zone)',
        'public.calculate_universe_evolution_rate(uuid)',
        'public.calculate_universe_evolution_rate_at(uuid,timestamp with time zone)',
        'public.calculate_planet_production(uuid)'
    ]
    loop
        v_ok := v_ok
                and not has_function_privilege('authenticated', v_fn, 'EXECUTE')
                and not has_function_privilege('anon', v_fn, 'EXECUTE')
                and has_function_privilege('service_role', v_fn, 'EXECUTE');
    end loop;
    /* …and the helpers that DO work (or that the allow-list protects) keep their grant */
    v_ok := v_ok
            and has_function_privilege('authenticated', 'public.calculate_planet_production_snapshot(uuid,numeric,numeric)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.calculate_building_cost(text,integer)', 'EXECUTE');
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8b. the twelve audited INVOKER helpers are engine-only (authenticated/anon revoked, service_role kept) while the working siblings keep authenticated');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 8c. the four DEAD client-reachable helpers (20260927140000): every possible client call could only ever return
        a permission error (INVOKER over `universes` / the engine analysis views / a revoked engine helper), no
        frontend/worker caller exists, and no DEFINER contract depends on the client grant. */
    v_ok := true;
    foreach v_fn in array array[
        'public.get_planet_economic_rates(uuid)',
        'public.get_planet_rate_snapshot(uuid)',
        'public.project_planet_resources(uuid,numeric)',
        'public.evaluate_action_at_time(uuid,text,text,numeric)'
    ]
    loop
        v_ok := v_ok
                and not has_function_privilege('authenticated', v_fn, 'EXECUTE')
                and not has_function_privilege('anon', v_fn, 'EXECUTE')
                and has_function_privilege('service_role', v_fn, 'EXECUTE');
    end loop;
    /* the contracts the UI really calls keep authenticated, including the variable-dispatched start_* family and the
       read contracts that were measured WORKING for a client */
    foreach v_fn in array array[
        'public.start_building(uuid,uuid,text)', 'public.start_research(uuid,uuid,text)',
        'public.start_ship(uuid,uuid,text,bigint)', 'public.start_defense(uuid,uuid,text,bigint)',
        'public.cancel_building(uuid)', 'public.cancel_research(uuid)',
        'public.get_planet_economy_overview(uuid)', 'public.get_planet_building_preview(uuid)',
        'public.ui_building_definitions()', 'public.ui_research_definitions()',
        'public.ui_ship_definitions()', 'public.ui_defense_definitions()',
        'public.get_current_planet_resources(uuid)', 'public.ui_defense_queue(uuid,uuid)',
        'public.ui_universe_galaxies()', 'public.get_universe_ranking(uuid,integer)',
        'public.inspect_demolition(uuid,uuid,text)', 'public.get_research_network_lab_level(uuid,uuid,text)'
    ]
    loop
        v_ok := v_ok and has_function_privilege('authenticated', v_fn, 'EXECUTE');
    end loop;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8c. the four dead client-reachable helpers are engine-only, and every UI-called / working read contract keeps authenticated');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 9. no function in `public` still carries an ACL-level PUBLIC grant */
    v_cnt := (select count(*) from pg_proc p
               where p.pronamespace = 'public'::regnamespace and coalesce(p.proacl::text, '') like '%{=X/%');
    v_ok := v_cnt = 0;
    insert into t_p3(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. no function in public keeps an ACL-level PUBLIC grant (%s left)', v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_p3(resultado, prueba) values ('INFO', format('failed assertions: %s', v_fail));

    if v_fail > 0 then
        raise exception 'P3 ACL FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_p3 order by orden;

drop table if exists t_p3;

rollback;
