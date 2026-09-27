-- ============================================================================
-- P3 ACL CLEANUP — SECOND WAVE: revoke `authenticated` on the four DEAD client-reachable helpers (2026-09-27)
-- ----------------------------------------------------------------------------
-- Found by the autonomous gameplay sweep (evidence-driven, not a pattern match): four `SECURITY INVOKER` helpers
-- are client-reachable while every possible client call can only ever FAIL. Measured LIVE as the DEV `authenticated`
-- actor in one rolled-back session (own planet, own player id):
--
--   get_planet_economic_rates(uuid)                    -> permission denied for table universes
--   get_planet_rate_snapshot(uuid)                     -> permission denied for table universes
--   project_planet_resources(uuid, numeric)            -> permission denied for function calculate_planet_production
--   evaluate_action_at_time(uuid, text, text, numeric) -> permission denied for view executable_optimization_candidates
--
-- ROOT CAUSE: they are SECURITY INVOKER and their dependency graph reaches artefacts that deliberately have NO client
-- grant (`public.universes`, the engine analysis views) or an engine-only helper revoked by `20260927130100`. Nothing
-- can change that for a client, so their `authenticated` grant is reachable surface that always errors — a UX trap
-- and an unjustified privilege.
--
-- AUDIT BEFORE REVOKING (this migration's preconditions + the recorded evidence):
--   * definition: all four are INVOKER (`prosecdef = false`), single-signature, in `public`.
--   * callers (LIVE, cross-checked): `get_planet_economic_rates` <- `get_planet_rate_snapshot` (also broken) and
--     `simulate_building_*` (client-unreachable since the C-02 hardening `20260921044643`);
--     `get_planet_rate_snapshot` <- `rank_building_sequences_snapshot` (client-unreachable, C-02);
--     `project_planet_resources` <- `evaluate_action_at_time` (also broken); `evaluate_action_at_time` <- nobody.
--     No SECURITY DEFINER contract calls any of them, so no engine path depends on the client grant.
--   * consumers: `src/**`, `worker/**` and `scripts/**` never call them. The real frontend inventory was re-derived
--     from EVERY `supabase.rpc(...)` call site, including the `start_building`/`start_research`/`start_ship`/
--     `start_defense` dispatches selected through a variable, which an earlier regex inventory had missed.
--   * fixtures: `acl_surface_p3.sql` asserted these grants on the premise that they are "internal dispatchers the UI
--     calls as a signed-in user". That premise is false, so the fixture is corrected in the same change: its
--     `v_internal` list is rebuilt from the real call sites and a new assertion 8c pins these four as engine-only.
--   * the certified owner-scoped contracts that cover the same UI need (`get_planet_economy_overview`,
--     `get_planet_building_preview`, `calculate_planet_storage`) are DEFINER, unaffected, and were re-measured as
--     WORKING for `authenticated` in the same sweep.
--
-- NOT touched: the 32-name allow-list; every UI-called contract (`start_*`, `cancel_*`, `get_planet_*`, `ui_*`);
-- `calculate_building_cost` / `calculate_research_cost` (they WORK for a client and expose no private data);
-- `get_current_planet_resources`, `ui_defense_queue`, `ui_universe_galaxies`, `get_universe_ranking`,
-- `inspect_demolition`, `get_research_network_lab_level` (all measured WORKING — revoking a working contract would
-- be the generic revocation the mission forbids).
--
-- No function is deleted, no ownership changes, no DEFINER conversion: only the useless grant is removed, so the
-- callers that legitimately exist (service_role workers, the owner, and the fixtures that run as the owner) are intact.
-- ============================================================================
begin;

do $acl$
declare
    v_targets text[] := array[
        'get_planet_economic_rates(uuid)',
        'get_planet_rate_snapshot(uuid)',
        'project_planet_resources(uuid,numeric)',
        'evaluate_action_at_time(uuid,text,text,numeric)'
    ];
    /* Contracts that must NOT be touched: the ones the UI really calls (re-derived from every `supabase.rpc(...)`
       call site, including the variable-dispatched start_* family), the 32-name anon allow-list, and the read
       contracts measured as WORKING for a client. */
    v_protected_names text[] := array[
        'start_building', 'start_research', 'start_ship', 'start_defense', 'cancel_building', 'cancel_research',
        'get_planet_economy_overview', 'get_planet_building_preview', 'ui_building_definitions',
        'ui_research_definitions', 'ui_ship_definitions', 'ui_defense_definitions', 'ui_defense_queue',
        'ui_universe_galaxies', 'get_current_planet_resources', 'get_universe_ranking', 'inspect_demolition',
        'get_research_network_lab_level', 'calculate_building_cost', 'calculate_research_cost',
        'can_build_defense', 'can_build_ship', 'can_start_building', 'can_start_demolition', 'can_start_research',
        'check_colony_cap', 'execute_jump_gate', 'get_player_battle_reports', 'get_player_espionage_reports',
        'get_player_expedition_reports', 'get_player_expedition_slot_status', 'get_player_fleet_slots',
        'get_player_messages', 'get_player_moons', 'get_player_support_authorizations',
        'get_universe_evolution_monitor_public', 'get_universe_ranking_by_category',
        'grant_planet_support_authorization', 'load_fleet_cargo', 'mark_message_read', 'provision_player',
        'recall_fleet', 'revoke_planet_support_authorization', 'scan_with_phalanx', 'start_colonize_fleet',
        'start_demolition', 'start_fleet', 'start_fleet_mixed', 'start_moon_destruction', 'start_support_fleet',
        'sync_current_planet_resources', 'use_expedition_item'
    ];
    v_sig text;
    v_oid oid;
    v_name text;
    v_revoked integer := 0;
begin
    foreach v_sig in array v_targets
    loop
        v_oid := to_regprocedure('public.' || v_sig);
        if v_oid is null then
            raise exception 'DEAD SURFACE ACL: public.% does not exist (audited list drift)', v_sig;
        end if;

        select p.proname into v_name from pg_proc p where p.oid = v_oid;

        if v_name = any (v_protected_names) then
            raise exception 'DEAD SURFACE ACL: % is called by the UI or allow-listed — refusing to revoke', v_sig;
        end if;
        if (select prosecdef from pg_proc where oid = v_oid) then
            raise exception 'DEAD SURFACE ACL: % is SECURITY DEFINER — out of scope', v_sig;
        end if;

        if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
            raise notice 'DEAD SURFACE ACL: % already revoked (idempotent skip)', v_sig;
            continue;
        end if;

        execute format('revoke execute on function public.%s from public, anon, authenticated', v_sig);
        execute format('grant execute on function public.%s to service_role', v_sig);
        v_revoked := v_revoked + 1;
    end loop;

    raise notice 'DEAD SURFACE ACL: % of % dead helper(s) revoked', v_revoked, array_length(v_targets, 1);

    /* postconditions: the four are engine-only… */
    foreach v_sig in array v_targets
    loop
        v_oid := to_regprocedure('public.' || v_sig);
        if has_function_privilege('authenticated', v_oid, 'EXECUTE')
           or has_function_privilege('anon', v_oid, 'EXECUTE')
           or not has_function_privilege('service_role', v_oid, 'EXECUTE') then
            raise exception 'DEAD SURFACE ACL POST: public.% is not engine-only', v_sig;
        end if;
    end loop;

    /* …while the UI contracts and the working read contracts keep their grant */
    foreach v_name in array array[
        'start_building(uuid,uuid,text)', 'start_research(uuid,uuid,text)', 'start_ship(uuid,uuid,text,bigint)',
        'start_defense(uuid,uuid,text,bigint)', 'cancel_building(uuid)', 'cancel_research(uuid)',
        'get_planet_economy_overview(uuid)', 'get_planet_building_preview(uuid)',
        'ui_building_definitions()', 'ui_research_definitions()', 'ui_ship_definitions()',
        'ui_defense_definitions()', 'calculate_building_cost(text,integer)',
        'get_current_planet_resources(uuid)', 'ui_defense_queue(uuid,uuid)', 'ui_universe_galaxies()',
        'get_universe_ranking(uuid,integer)', 'inspect_demolition(uuid,uuid,text)',
        'get_research_network_lab_level(uuid,uuid,text)'
    ]
    loop
        v_oid := to_regprocedure('public.' || v_name);
        if v_oid is null then
            raise exception 'DEAD SURFACE ACL POST: protected function public.% is missing', v_name;
        end if;
        if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
            raise exception 'DEAD SURFACE ACL POST: public.% lost its authenticated EXECUTE', v_name;
        end if;
    end loop;

    raise notice 'DEAD SURFACE ACL: UI contracts and working read contracts keep authenticated';
end;
$acl$;

commit;
