-- ============================================================================
-- P3 ACL CLEANUP — FOLLOW-UP: close the PUBLIC (`=X`) EXECUTE grant (2026-09-26)
-- ----------------------------------------------------------------------------
-- 20260926299000 revoked the explicit `anon` entry but the ACLs also carried `=X` — the PUBLIC pseudo-role —
-- and PUBLIC is what actually keeps a function anonymous-reachable. Measured LIVE after that migration:
-- 97 functions outside the client allow-list were still `has_function_privilege('anon', …) = true`, all of them
-- through `=X`. A new function created by the migration role inherits PUBLIC as well, which is why the fixture's
-- behavioural probe still saw an anon-executable function.
--
-- This migration:
--   1. keeps EXACTLY the access `authenticated` has today: for the 19 functions where that access came only from
--      PUBLIC (their ACL has no `authenticated=X`), an explicit GRANT is written first, so the caller graph of
--      every authenticated RPC keeps working;
--   2. then revokes EXECUTE from PUBLIC and `anon` on every function outside the 32-name client allow-list;
--   3. removes PUBLIC from the default privileges of the `public` schema, so the next function is not born
--      publicly executable.
--
-- Untouched, deliberately: the client allow-list (32 RPCs), `get_universe_*public*` contracts, table grants
-- (RLS already denies them — DEFER), and the `supabase_admin` default ACL (migrations here run as `postgres`).
-- ============================================================================

do $acl$
declare
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
    r record;
    v_closed integer := 0;
    v_kept integer := 0;
begin
    for r in
        select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args,
               has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_has,
               coalesce(p.proacl::text, '') like '%authenticated=X%' as auth_explicit
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and has_function_privilege('anon', p.oid, 'EXECUTE')
           and not (p.proname = any (v_client_rpc))
         order by p.proname
    loop
        if r.auth_has and not r.auth_explicit then
            execute format('grant execute on function public.%I(%s) to authenticated', r.proname, r.args);
            v_kept := v_kept + 1;
        end if;
        execute format('revoke execute on function public.%I(%s) from public, anon', r.proname, r.args);
        v_closed := v_closed + 1;
    end loop;
    raise notice 'P3 ACL follow-up: PUBLIC closed on % functions; authenticated preserved explicitly on %',
        v_closed, v_kept;
end;
$acl$;

alter default privileges for role postgres in schema public revoke execute on functions from public;