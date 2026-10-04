-- ============================================================================================
-- ACL — four client-reachable helpers whose ONLY possible client outcome is an error or a
--       provably wrong answer. The engine keeps them; the browser must not.
-- ============================================================================================
-- GAP (2026-09-29, backend->UI / orphan-contract sweep). Two earlier P3 passes already closed this
-- exact class: `20260927130100` (twelve audited INVOKER helpers) and `20260927140000` (four
-- "dead client invoker helpers"). A fresh sweep of the LIVE `authenticated` surface against the
-- static UI inventory found FOUR MORE members, and this time each one is PROVEN wrong rather than
-- merely unused.
--
-- MEASURED LIVE, same data, same arguments, only the role differs (this is the whole proof):
--
--   contract                                        engine (owner)          client (authenticated)
--   can_recycle_debris(own fleet, real field)       true                     FALSE   <- wrong answer
--   get_expedition_ship_candidates(own fleet)       5 candidates             EXCEPTION
--   get_active_expedition_item_effect(own, own)     42                       0       <- wrong answer
--   check_defense_requirements(OWN planet)          allowed/OK               "permission denied for
--                                                                                    table
--                                                                                    defense_prerequisites"
--
-- WHY. All four are `SECURITY INVOKER`, so for a client the RLS of the underlying table decides the
-- result, not the function's logic:
--   * `debris_fields`             -> policy `deny_direct_api_access` (qual = false): a client reads 0
--                                    rows, so `can_recycle_debris` can only ever answer false. The
--                                    player-facing RECYCLE availability oracle is
--                                    `get_recyclable_debris_status` (a DEFINER contract, already
--                                    shipped and certified in 20260928220000), not this helper.
--   * `expedition_ship_tiers`     -> same deny policy, so `calculate_expedition_max_ship_tier` finds
--                                    MAX(tier) = 0 and RAISES "contains no eligible expedition ships".
--   * `expedition_item_uses`      -> same deny policy, so the effect always sums to 0.
--   * `defense_prerequisites`     -> not SELECT-granted to `authenticated` at all, so the call dies
--                                    with a permission error instead of an answer. The contract the UI
--                                    actually uses is `can_build_defense`.
-- A helper that can only ever answer "wrong" or "error" is worse than an absent one: it looks like
-- a supported capability and invites a future consumer to build on a lie.
--
-- NO CLIENT CALLER. The UI inventory is derived mechanically by `scripts/contract-inventory.mjs`
-- from every `supabase.rpc('…')` / `rpcUntyped('…')` call site in `src/**` (47 names). None of these
-- four appears. The engine, the fleet worker, the expedition resolvers and the AI all run as
-- `postgres`/`service_role`, which keep the grant, so revoking `authenticated` cannot affect them.
--
-- Deliberately NOT touched: every `calculate_*` / `select_expedition_*` / `inspect_expedition_*`
-- helper, every DEFINER contract, the whole `start_*` / `cancel_*` dispatcher family, the four
-- `ui_*_definitions` readers, `get_player_*` read contracts, and the Lifeforms surface (DEFERRED).
-- `get_expedition_ship_candidates` and `get_active_expedition_item_effect` keep working for the
-- engine; only the browser's useless access is removed.
-- ============================================================================================

do $revoke$
declare
    v_targets text[] := array[
        'can_recycle_debris',
        'get_expedition_ship_candidates',
        'get_active_expedition_item_effect',
        'check_defense_requirements'
    ];
    v_name text;
    v_rec record;
    v_counted integer := 0;
begin
    foreach v_name in array v_targets loop
        -- One statement PER OVERLOAD. A bare `on function public.<name>` is rejected by PostgreSQL
        -- when the name is not unique, and `get_active_expedition_item_effect` has two overloads.
        for v_rec in
            select p.oid::regprocedure::text as sig
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = v_name
        loop
            execute format('revoke all on function %s from public', v_rec.sig);
            execute format('revoke all on function %s from anon', v_rec.sig);
            execute format('revoke all on function %s from authenticated', v_rec.sig);
            -- service_role and the owner keep EXECUTE: this narrows the surface, it never removes a
            -- capability the engine or the worker uses.
            execute format('grant execute on function %s to service_role', v_rec.sig);
            v_counted := v_counted + 1;
        end loop;
        if v_counted = 0 then
            raise exception 'ACL_WRONG_CLIENT_HELPERS: % does not exist in public', v_name;
        end if;
    end loop;
    raise notice 'ACL_WRONG_CLIENT_HELPERS: % overload(s) revoked', v_counted;
end;
$revoke$;



-- Post-conditions. The "no UI contract lost a grant" one is the important one: revoking may not
-- cost a single grant the browser actually uses, so the whole inventory is re-asserted here rather
-- than trusted. It is the `scripts/contract-inventory.mjs` list over `src/**` (48 names).
do $verify$
declare
    v_targets text[] := array[
        'can_recycle_debris', 'get_expedition_ship_candidates',
        'get_active_expedition_item_effect', 'check_defense_requirements'
    ];
    v_ui text[] := array[
        'can_build_defense','can_build_ship','can_start_building','can_start_demolition',
        'can_start_research','cancel_building','cancel_research','check_colony_cap',
        'execute_jump_gate','get_my_attack_protection','get_planet_building_preview',
        'get_planet_economy_overview','get_player_battle_reports','get_player_espionage_reports',
        'get_player_expedition_item_status','get_player_expedition_merchant',
        'get_player_expedition_reports','get_player_expedition_slot_status','get_player_fleet_slots',
        'get_player_messages','get_player_moons','get_player_research_lab_status',
        'get_player_support_authorizations','get_player_transport_movements',
        'get_recyclable_debris_status','get_universe_debris','get_universe_evolution_monitor_public',
        'get_universe_ranking_by_category','grant_planet_support_authorization','load_fleet_cargo',
        'mark_message_read','provision_player','recall_fleet','revoke_planet_support_authorization',
        'scan_with_phalanx','start_building','start_colonize_fleet','start_defense','start_demolition',
        'start_fleet','start_fleet_mixed','start_moon_destruction','start_research','start_ship',
        'start_support_fleet','sync_current_planet_resources','trade_with_expedition_merchant',
        'ui_building_definitions','ui_defense_definitions','ui_research_definitions',
        'ui_ship_definitions','use_expedition_item'
    ];
    v_name text;
    v_lost integer;
begin
    -- 1. every target lost authenticated / anon / PUBLIC
    foreach v_name in array v_targets loop
        if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = v_name
                      and has_function_privilege('authenticated', p.oid, 'EXECUTE')) then
            raise exception 'ACL_WRONG_CLIENT_HELPERS: % is still authenticated-executable', v_name;
        end if;
        if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = v_name
                      and (has_function_privilege('anon', p.oid, 'EXECUTE')
                           or has_function_privilege('public', p.oid, 'EXECUTE'))) then
            raise exception 'ACL_WRONG_CLIENT_HELPERS: % still reachable by anon/PUBLIC', v_name;
        end if;
    end loop;

    -- 2. the ENGINE keeps them: an ACL narrowing, never a capability loss
    foreach v_name in array v_targets loop
        if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'public' and p.proname = v_name
                          and has_function_privilege('service_role', p.oid, 'EXECUTE')) then
            raise exception 'ACL_WRONG_CLIENT_HELPERS: % lost service_role (the engine would break)', v_name;
        end if;
    end loop;


    -- 3. NO UI contract may have lost its grant
    select count(*) into v_lost
      from unnest(v_ui) u(name)
      join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace
     where not has_function_privilege('authenticated', p.oid, 'EXECUTE');
    if v_lost > 0 then
        raise exception 'ACL_WRONG_CLIENT_HELPERS: % UI contract(s) lost authenticated EXECUTE', v_lost;
    end if;

    -- 4. a target must not also appear in the UI inventory
    if exists (select 1 from unnest(v_ui) u(name) where u.name = any(v_targets)) then
        raise exception 'ACL_WRONG_CLIENT_HELPERS: a target also appears in the UI inventory';
    end if;

    -- 5. the certified player-facing replacements stay client-reachable
    if not has_function_privilege('authenticated', 'public.get_recyclable_debris_status()', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.can_build_defense(uuid,uuid,text,bigint)', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.get_player_expedition_reports(integer)', 'EXECUTE') then
        raise exception 'ACL_WRONG_CLIENT_HELPERS: a certified replacement contract lost its grant';
    end if;

    -- 6. the RLS that made them wrong is untouched (this migration changes no policy)
    if not exists (select 1 from pg_policy where polname = 'deny_direct_api_access'
                     and polrelid = 'public.debris_fields'::regclass)
       or not exists (select 1 from pg_policy where polname = 'deny_direct_api_access'
                        and polrelid = 'public.expedition_ship_tiers'::regclass)
       or not exists (select 1 from pg_policy where polname = 'deny_direct_api_access'
                        and polrelid = 'public.expedition_item_uses'::regclass) then
        raise exception 'ACL_WRONG_CLIENT_HELPERS: a deny_direct_api_access policy was altered';
    end if;
end;
$verify$;
