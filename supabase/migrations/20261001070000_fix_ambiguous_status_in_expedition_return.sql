-- EXPEDITION RETURN: an ambiguous column reference made every expedition return leg fail forever.
-- ---------------------------------------------------------------------------------------------
-- THE DEFECT (measured on LIVE 2026-10-01, and reproducible with one statement)
--
--   `resolve_expedition_return` RETURNS TABLE(..., status text). The OUT parameter `status` is a
--   PL/pgSQL VARIABLE, and `fleet_movements.status` is a COLUMN of the table it updates. The final
--   statement referenced it unqualified:
--
--       UPDATE public.fleet_movements
--       SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
--       WHERE id = p_fleet_id AND status = 'RETURNING';
--
--   With the default `plpgsql.variable_conflict = error`, that reference is ambiguous and Postgres
--   REJECTS THE STATEMENT -- it is a plan-time error, so it fires on EVERY execution:
--
--       ERROR:  42702: column reference "status" is ambiguous
--       DETAIL:  It could refer to either a PL/pgSQL variable or a table column.
--       QUERY:   UPDATE public.fleet_movements ... WHERE id = p_fleet_id AND status = 'RETURNING'
--
--   It is NOT a transient failure. The caller is the fleet worker's RETURNING loop, whose per-fleet
--   handler downgrades any error to `raise warning 'FLEET_RESOLUTION_FAILED ...'`, which rolls
--   nothing back and surfaces nothing.
--
--   CONSEQUENCE -- 100 % of expedition returns were broken:
--     * the movement never leaves RETURNING;
--     * its ships (already debited at dispatch) are destroyed -- expeditions are the one mission
--       where the player normally expects to KEEP the fleet, so this is the most visible form;
--     * `get_player_fleet_slots` counts every movement whose status is not in ('COMPLETED',
--       'CANCELLED'), so the player permanently loses one fleet slot per expedition.
--       With computer_technology 0 (1 slot) a single expedition is a total fleet lock.
--
--   LIVE EVIDENCE (read-only at the time of the audit): exactly one movement was stuck --
--   EXPEDITION d79a0bd0-5aa4-4195-991d-363cda138353, RETURNING with returns_at 13 h in the past,
--   5 large_cargo on board, origin planet f35bd4b9. Calling the deployed function on it raised 42702.
--
--   WHY THE OTHER FIVE RESOLVERS WERE NOT AFFECTED (and the fix therefore matches their convention):
--   every sibling aliases the target table, so its columns are never ambiguous:
--       resolve_transport_arrival  ... AS fm   WHERE fm.id = p_fleet_id
--       resolve_deploy_arrival     ... AS fm
--       resolve_colonize_arrival   ... AS fm
--       resolve_espionage_arrival  ... AS fm / AS pd
--       process_defense_queue      ... AS dq   AND dq.status = 'BUILDING'
--       process_shipyard_queue     ... AS sq   AND sq.status = 'BUILDING'
--   `resolve_expedition_return` was the only one missing the alias.
--
-- THE FIX
--   Alias the update exactly like the siblings. One statement, one alias, nothing else.
--   The OUT parameter is deliberately NOT renamed: `status` is part of the published column list of
--   this contract and renaming it would be a breaking change for every consumer.
--
-- NOT CHANGED
--   * The settlement clamp (greatest(returns_at, last_calculated_at)) introduced by 20260930240000.
--   * The 'Expedition must be RETURNING' guard, the ship write-back, the cargo credit, the returned
--     values and the idempotency of the whole resolver.
--   * The function SIGNATURE (`RETURNS TABLE(fleet_id uuid, origin_planet_id uuid, delivered_metal
--     numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)`), its volatility
--     (VOLATILE), its SECURITY (INVOKER) and its `SET search_path`: the body is spliced out of
--     pg_get_functiondef, never retyped.
--   * ACL: the function stays executable ONLY by service_role, never by anon or authenticated.
--
-- EDIT METHOD
--   Anchored text splice over the COMPLETE pg_get_functiondef output, the same technique as
--   20261001010000 / 20261001030000 / 20261001040000 / 20261001060000. The anchor is asserted to
--   occur exactly ONCE before the splice.
do $expedition$
declare
    v_src text; v_def text; v_n integer;
begin
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'EXPEDITION: resolve_expedition_return not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'UPDATE public\.fleet_movements\s+SET metal = 0, crystal = 0, deuterium = 0, status = ''COMPLETED''\s+WHERE id = p_fleet_id AND status = ''RETURNING'';',
        'g');
    if v_n <> 1 then
        raise exception 'EXPEDITION: ambiguous anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def,
        '    UPDATE public.fleet_movements'||chr(10)
     || '    SET metal = 0, crystal = 0, deuterium = 0, status = ''COMPLETED'''||chr(10)
     || '    WHERE id = p_fleet_id AND status = ''RETURNING'';',

        '-- FIX 2026-10-01: see the header. `status` is BOTH an OUT parameter of this function and a'||chr(10)
     || '    -- column of fleet_movements, so the unqualified reference below was rejected with'||chr(10)
     || '    -- 42702 "column reference is ambiguous" on EVERY call: no expedition return could ever'||chr(10)
     || '    -- complete. The table is aliased exactly like every sibling arrival resolver'||chr(10)
     || '    -- (resolve_transport_arrival / resolve_deploy_arrival / resolve_colonize_arrival /'||chr(10)
     || '    -- resolve_espionage_arrival). The OUT parameter keeps its published name.'||chr(10)
     || '    UPDATE public.fleet_movements AS fm'||chr(10)
     || '    SET metal = 0, crystal = 0, deuterium = 0, status = ''COMPLETED'''||chr(10)
     || '    WHERE fm.id = p_fleet_id AND fm.status = ''RETURNING'';');

    execute v_def;
/* ================= POSTCONDITIONS: fix present, contract intact ================= */

    -- 1. the ambiguity is gone and the alias is in place
    if (select p.prosrc from pg_proc p
         where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       ilike '%AND fm.status = ''RETURNING''%' then
        null;
    else
        raise exception 'POSTCONDITION FAILED: the qualified status predicate is not deployed';
    end if;

    if (select p.prosrc from pg_proc p
         where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       ilike '%WHERE id = p_fleet_id AND status = ''RETURNING''%' then
        raise exception 'POSTCONDITION FAILED: the ambiguous reference is still present';
    end if;

    -- 2. the published result columns are untouched (renaming `status` would break consumers)
    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       <> 'TABLE(fleet_id uuid, origin_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)'
    then
        raise exception 'POSTCONDITION FAILED: the result column list changed';
    end if;

    -- 3. the guard, the clamp and the credit are all still there
    if (select p.prosrc from pg_proc p
         where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       not ilike '%Expedition must be RETURNING%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       not ilike '%last_calculated_at%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       not ilike '%SET metal = 0, crystal = 0, deuterium = 0, status = ''COMPLETED''%' then
        raise exception 'POSTCONDITION FAILED: the resolver lost its guard, its clamp or its close';
    end if;

    -- 4. volatility / security / search_path are carried over verbatim by pg_get_functiondef
    if (select p.provolatile from pg_proc p
         where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace) <> 'v'
       or (select p.prosecdef from pg_proc p
            where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
       or (select array_to_string(p.proconfig, ',') from pg_proc p
            where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
          <> 'search_path=public, pg_temp' then
        raise exception 'POSTCONDITION FAILED: volatility / SECURITY / search_path changed';
    end if;

    -- 5. ACL unchanged: internal to the worker, never client-executable
    if has_function_privilege('authenticated', 'public.resolve_expedition_return(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.resolve_expedition_return(uuid)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.resolve_expedition_return(uuid)', 'EXECUTE') then
        raise exception 'POSTCONDITION FAILED: the ACL changed';
    end if;

    -- 6. the sibling resolvers were NOT touched (they were already correct)
    foreach v_src in array array['resolve_transport_arrival','resolve_deploy_arrival',
                                 'resolve_colonize_arrival']
    loop
        if (select p.prosrc from pg_proc p
             where p.proname = v_src and p.pronamespace = 'public'::regnamespace)
           ilike '%AND status = ''RETURNING''%' then
            raise exception 'POSTCONDITION FAILED: % is ambiguous too and was not fixed', v_src;
        end if;
    end loop;
end;
$expedition$;
-- ---------------------------------------------------------------------------------------------