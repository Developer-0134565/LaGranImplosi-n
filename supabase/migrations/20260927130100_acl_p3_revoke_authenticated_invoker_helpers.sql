-- ============================================================================
-- P3 ACL CLEANUP — revoke `authenticated` on the audited SECURITY INVOKER helpers (2026-09-27)
-- ----------------------------------------------------------------------------
-- SCOPE: exactly the list identified by the ACL audit (README_ECONOMY, "Planet resources / storage read contracts",
-- residual paragraph) — the `SECURITY INVOKER` gameplay helpers that are reachable by `authenticated` because
-- `20260926300000` re-granted them explicitly when PUBLIC was their only source, and that have NO client caller:
--
--   calculate_building_time(text, integer, uuid)
--   calculate_ship_build_time(uuid, text)
--   calculate_defense_build_time(uuid, text)
--   calculate_research_time(uuid, text, integer)          <- legacy INVOKER overload
--   calculate_research_time(text, integer, uuid)          <- legacy INVOKER overload
--   calculate_lifeform_building_time(uuid, text, integer)
--   calculate_lifeform_research_time(uuid, text, integer)
--   calculate_universe_evolution_population_seconds(uuid, timestamptz, timestamptz)
--   calculate_universe_evolution_production_seconds(uuid, timestamptz, timestamptz)
--   calculate_universe_evolution_rate(uuid)
--   calculate_universe_evolution_rate_at(uuid, timestamptz)
--   calculate_planet_production(uuid)
--
-- EVIDENCE (measured LIVE 2026-09-27 as the DEV `authenticated` actor BEFORE this migration; recorded in
-- docs/systems/README_ECONOMY.md):
--   * EVERY one of the twelve FAILS today for `authenticated`: being SECURITY INVOKER they evaluate
--     `public.universes`, which has no client SELECT grant by design -> "permission denied for table universes".
--     The two lifeform helpers additionally cannot resolve their definition id, so they are unusable through the
--     client surface in any case.
--   * No frontend/worker caller exists: `src/**`, `worker/**` and `scripts/**` never invoke them (the only
--     repository reference is the generated `src/lib/database.types.ts`; `scripts/verify-buildings.mjs` probes
--     `calculate_planet_production` and SKIPS on error by design).
--   * Their LIVE callers are either SECURITY DEFINER (privilege checked against the owner `postgres`, unaffected by
--     a revoke) or INVOKER functions that are already unreachable from the client (`simulate_*`,
--     `evaluate_building_chain`, `calculate_universe_rates`) or INVOKER functions that fail today for the same
--     `universes` reason (`project_planet_resources`, `calculate_planet_energy_balance`): the latter keep their own
--     grant, so no working client path exists to break.
--   * No fixture asserts `authenticated` EXECUTE on any of the twelve (verified across `supabase/tests/**`).
--
-- NOT TOUCHED, deliberately: the 32-name client allow-list; the trio the certified P3 fixture protects
-- (`calculate_building_cost`, `project_planet_resources`, `evaluate_action_at_time`); every DEFINER contract
-- (`can_start_research`, `start_research`, `get_planet_economy_overview`, …), whose internal calls run as the owner;
-- and `calculate_planet_production_snapshot`, which WORKS for `authenticated` (measured) and is not in the list.
--
-- After this migration the twelve keep exactly what their real consumers need: `service_role` (and the owner).
-- ============================================================================
begin;

do $acl$
declare
    v_targets text[] := array[
        'calculate_building_time(text,integer,uuid)',
        'calculate_ship_build_time(uuid,text)',
        'calculate_defense_build_time(uuid,text)',
        'calculate_research_time(uuid,text,integer)',
        'calculate_research_time(text,integer,uuid)',
        'calculate_lifeform_building_time(uuid,text,integer)',
        'calculate_lifeform_research_time(uuid,text,integer)',
        'calculate_universe_evolution_population_seconds(uuid,timestamp with time zone,timestamp with time zone)',
        'calculate_universe_evolution_production_seconds(uuid,timestamp with time zone,timestamp with time zone)',
        'calculate_universe_evolution_rate(uuid)',
        'calculate_universe_evolution_rate_at(uuid,timestamp with time zone)',
        'calculate_planet_production(uuid)'
    ];
    v_client_rpc text[] := array[
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
    v_sig text;
    v_oid oid;
    v_name text;
    v_seen integer := 0;
    v_revoked integer := 0;
    v_protected text;
begin
    /* --- preconditions: every signature exists, is INVOKER, keeps `authenticated`, is NOT a client contract --- */
    foreach v_sig in array v_targets
    loop
        v_oid := to_regprocedure('public.' || v_sig);
        if v_oid is null then
            raise exception 'P3 ACL: public.% does not exist (audited list drift)', v_sig;
        end if;

        select p.proname into v_name from pg_proc p where p.oid = v_oid;

        if v_name = any (v_client_rpc) then
            raise exception 'P3 ACL: % is part of the client allow-list — refusing to revoke', v_sig;
        end if;
        if (select prosecdef from pg_proc where oid = v_oid) then
            raise exception 'P3 ACL: % is SECURITY DEFINER — out of scope for this cleanup', v_sig;
        end if;
        if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
            raise notice 'P3 ACL: % already lacks authenticated EXECUTE (idempotent skip)', v_sig;
            continue;
        end if;

        v_seen := v_seen + 1;
        execute format('revoke execute on function public.%s from public, anon, authenticated', v_sig);
        execute format('grant execute on function public.%s to service_role', v_sig);
        v_revoked := v_revoked + 1;
    end loop;

    if v_seen = 0 then
        raise notice 'P3 ACL: every audited helper was already revoked (nothing to do)';
    else
        raise notice 'P3 ACL: authenticated EXECUTE revoked on % of % audited helper(s)', v_revoked, array_length(v_targets, 1);
    end if;

    /* --- postconditions: the twelve are engine-only, and nothing protected moved --- */
    foreach v_sig in array v_targets
    loop
        v_oid := to_regprocedure('public.' || v_sig);
        if has_function_privilege('authenticated', v_oid, 'EXECUTE')
           or has_function_privilege('anon', v_oid, 'EXECUTE')
           or not has_function_privilege('service_role', v_oid, 'EXECUTE') then
            raise exception 'P3 ACL POST: public.% is not engine-only (authenticated=%, anon=%, service_role=%)',
                v_sig,
                has_function_privilege('authenticated', v_oid, 'EXECUTE'),
                has_function_privilege('anon', v_oid, 'EXECUTE'),
                has_function_privilege('service_role', v_oid, 'EXECUTE');
        end if;
        if (select coalesce(p.proacl::text, '') from pg_proc p where p.oid = v_oid) like '%{=X/%' then
            raise exception 'P3 ACL POST: public.% still carries an ACL-level PUBLIC grant', v_sig;
        end if;
    end loop;

    foreach v_protected in array array[
        'calculate_building_cost(text,integer)',
        'project_planet_resources(uuid,numeric)',
        'evaluate_action_at_time(uuid,text,text,numeric)',
        'calculate_planet_production_snapshot(uuid,numeric,numeric)',
        'start_building(uuid,uuid,text)',
        'start_research(uuid,uuid,text)',
        'start_ship(uuid,uuid,text,bigint)',
        'start_defense(uuid,uuid,text,bigint)',
        'inspect_demolition(uuid,uuid,text)'
    ]
    loop
        v_oid := to_regprocedure('public.' || v_protected);
        if v_oid is null then
            raise exception 'P3 ACL POST: protected function public.% is missing', v_protected;
        end if;
        if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
            raise exception 'P3 ACL POST: public.% lost its authenticated EXECUTE (legitimate consumer)', v_protected;
        end if;
    end loop;

    raise notice 'P3 ACL: audited INVOKER helpers are engine-only; protected contracts keep authenticated';
end;
$acl$;

commit;
