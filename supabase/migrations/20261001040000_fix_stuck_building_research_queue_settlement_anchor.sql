-- BUILDING / RESEARCH STUCK-STATE: a due queue event whose timestamp is already behind the
-- planet clock raised INVALID_RESOURCE_TIMESTAMP forever and aborted the whole universe tick.
-- ---------------------------------------------------------------------------------------------
-- DECISION GATE -- the semantics were DETERMINED from the existing code, not invented:
--
--   Option A -- COMPLETE the overdue queue. This is what LGI already does:
--     * `process_planet_tick` selects it with `finishes_at <= now()`: anything due is completed.
--     * `complete_building` and `complete_research` contain NO CANCELLED branch and NO DELETE:
--       they can only complete or raise. There is no abandonment path.
--     * Only `cancel_building` / `cancel_research` set 'CANCELLED', and those are explicit PLAYER
--       actions that refund the cost. Nothing automatic ever cancels a queue row.
--     * Both completions are idempotent on 'COMPLETED' (return the level / false), so completing
--       an overdue row is exactly the already-certified path.
--   Option B -- DISCARD the overdue queue. No code, status transition or refund rule would do this
--     automatically; inventing it would silently destroy a paid queue row.
--
--   => A. An overdue queue is completed, settled through a clamped anchor.
--
-- THE DEFECT (measured on LIVE 2026-10-01, ROLLBACK probes)
--   Both completions settle the economy AT THE EVENT TIMESTAMP through
--   `update_planet_resources_until_raw`, which deliberately refuses to move a planet's clock
--   BACKWARDS (INVALID_RESOURCE_TIMESTAMP). That guard is correct and is NOT touched.
--
--     complete_building  -> update_planet_resources_until_raw(planet, queue.finishes_at)
--     complete_research  -> update_planet_resources_until_raw(every planet of the player,
--                                                        research.finishes_at)
--
--   Measured: an overdue research whose planet clock was already past `finishes_at`
--     -> process_planet_tick => P0001 : INVALID_RESOURCE_TIMESTAMP
--     -> the research_queue row stays 'RESEARCHING' FOREVER (3 retries, identical)
--     -> and because process_universe_tick has no per-planet error isolation, the exception
--        propagates: NO planet in that universe settles on that heartbeat.
--
--   How the clock gets ahead of a still-pending queue row (ordinary event order):
--   `process_planet_tick_local` and the UI settle through the walking wrapper, which completes due
--   events first. But the FLEET/COMBAT anchors use the RAW variant and do NOT walk events
--   (resolve_attack_arrival -> apply_attack_loot, resolve_expedition_return, ...), so a planet can
--   be settled straight past a pending research/building event. After that the event is invisible
--   to the walker (`finishes_at > last_calculated_at` no longer holds) yet still visible to the
--   tick predicate (`finishes_at <= now()`): that is exactly the stuck window.
--
--   `complete_research` amplifies it: it loops EVERY planet of the player, so ONE advanced planet
--   aborts the loop and the research never completes for anyone.
--
-- THE FIX
--   The SAME clamp already accepted for the fleet stuck-states (20260930240000/241000 and
--   20261001030000), one per settlement:
--       greatest(<queue timestamp>, <that planet's own last_calculated_at>)
--   * Event in the FUTURE (the normal certified path) -> no-op, settlement stays byte-identical.
--   * Event behind -> no elapsed time left to credit, so settling at the planet's own clock grants
--     ZERO extra production and the queue completes normally.
--
--   Per-planet isolation in `complete_research`: the clamp is computed INSIDE the loop against the
--   planet being settled, so a planet already past the event is settled at its own clock (a no-op)
--   instead of raising and aborting the remaining planets and the research grant. This introduces
--   NO new business semantics: the research still completes exactly once.
--
-- NOT CHANGED
--   * `update_planet_resources_until_raw` and its INVALID_RESOURCE_TIMESTAMP guard.
--   * The `_raw` variant is kept on purpose: it is what avoids recursive event processing while a
--     walker is already walking this exact event.
--   * The idempotency guards (`status='COMPLETED'` -> return level/false), the level grants, the
--     `fields_used` increment, the downgrade path, and every function SIGNATURE, volatility,
--     SECURITY and `SET search_path` (bodies are spliced out of pg_get_functiondef, never retyped).
--   * `cancel_building` / `cancel_research`: the explicit player-refund path is untouched.
--
-- EDIT METHOD
--   Anchored text splice over the COMPLETE pg_get_functiondef output, the same technique as
--   20261001010000_economic_sustainability_guard.sql and 20261001030000. Each anchor is asserted to
--   occur exactly ONCE before the splice.
do $clamp$
declare
    v_src text; v_def text; v_n integer;
begin
    /* ============================ 1. complete_building ============================ */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'complete_building' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: complete_building not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until_raw\(v_queue\.planet_id, v_queue\.finishes_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: complete_building anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'complete_building' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def, 'v_queue public.building_queue%rowtype;',
                                'v_queue public.building_queue%rowtype; v_settle_at timestamptz;');

    v_def := replace(v_def,
        '    PERFORM * FROM public.update_planet_resources_until_raw(v_queue.planet_id, v_queue.finishes_at);',
        E'    -- CLAMP 2026-10-01: see the header. A due queue whose timestamp is already behind the\r\n'
     || E'    -- planet clock raised INVALID_RESOURCE_TIMESTAMP on every heartbeat, leaving the\r\n'
     || E'    -- building stuck in BUILDING forever and aborting the whole universe tick.\r\n'
     || E'    SELECT greatest(v_queue.finishes_at, pr.last_calculated_at) INTO v_settle_at\r\n'
     || E'      FROM public.planet_resources pr WHERE pr.planet_id = v_queue.planet_id;\r\n'
     || E'    PERFORM * FROM public.update_planet_resources_until_raw(\r\n'
     || E'        v_queue.planet_id, coalesce(v_settle_at, v_queue.finishes_at));');

    execute v_def;

    /* ============================ 2. complete_research ============================ */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'complete_research' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: complete_research not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until_raw\(v_planet_id_iter,v_finishes_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: complete_research anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'complete_research' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def, 'v_finishes_at timestamptz;',
                                'v_finishes_at timestamptz; v_settle_at timestamptz;');

    v_def := replace(v_def,
        '  perform public.update_planet_resources_until_raw(v_planet_id_iter,v_finishes_at);',
        E'  -- CLAMP 2026-10-01: see the header. The clamp is computed PER PLANET inside the\r\n'
     || E'  -- loop, so one planet already past the event is settled at its own clock (a no-op)\r\n'
     || E'  -- instead of raising and aborting both the remaining planets and the research grant.\r\n'
     || E'  select greatest(v_finishes_at, pr.last_calculated_at) into v_settle_at\r\n'
     || E'    from public.planet_resources pr where pr.planet_id = v_planet_id_iter;\r\n'
     || E'  perform public.update_planet_resources_until_raw(\r\n'
     || E'    v_planet_id_iter, coalesce(v_settle_at, v_finishes_at));');
execute v_def;

    /* ===================== POSTCONDITIONS: fix present, guard intact ===================== */
    foreach v_src in array array['complete_building','complete_research']
    loop
        if (select p.prosrc from pg_proc p
             where p.proname = v_src and p.pronamespace = 'public'::regnamespace)
           not ilike '%last_calculated_at%' then
            raise exception 'POSTCONDITION FAILED: % is not clamped', v_src;
        end if;
    end loop;

    -- the settlement guard itself must be untouched
    if (select p.prosrc from pg_proc p
         where p.proname = 'update_planet_resources_until_raw'
           and p.pronamespace = 'public'::regnamespace')
       not ilike '%INVALID_RESOURCE_TIMESTAMP%' then
        raise exception 'POSTCONDITION FAILED: the settlement guard was weakened';
    end if;

    -- signatures must be unchanged
    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'complete_building' and p.pronamespace = 'public'::regnamespace) <> 'integer' then
        raise exception 'POSTCONDITION FAILED: complete_building signature changed';
    end if;

    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'complete_research' and p.pronamespace = 'public'::regnamespace) <> 'boolean' then
        raise exception 'POSTCONDITION FAILED: complete_research signature changed';
    end if;

    -- idempotency guards must survive the splice
    foreach v_src in array array['complete_building','complete_research']
    loop
        if (select p.prosrc from pg_proc p
             where p.proname = v_src and p.pronamespace = 'public'::regnamespace')
           not ilike '%COMPLETED%' then
            raise exception 'POSTCONDITION FAILED: % lost its COMPLETED idempotency guard', v_src;
        end if;
    end loop;

    -- security posture must be unchanged: these stay internal, never client-executable
    if has_function_privilege('authenticated', 'public.complete_building(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.complete_building(uuid)', 'EXECUTE') then
        raise exception 'POSTCONDITION FAILED: complete_building became client-executable';
    end if;

    if has_function_privilege('authenticated', 'public.complete_research(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.complete_research(uuid)', 'EXECUTE') then
        raise exception 'POSTCONDITION FAILED: complete_research became client-executable';
    end if;
end;
$clamp$;

    execute v_def;
-- ---------------------------------------------------------------------------------------------