-- FLEET STUCK-STATE, SIBLING GAP: four arrival/settlement anchors were never clamped
-- ---------------------------------------------------------------------------------------------
-- SIBLING of 20260930240000 + 20260930241000. Those two migrations closed the trap for the
-- RETURNING leg and for two arrival resolvers, but they enumerate a FIXED list of call sites.
-- Four more settlement anchors kept passing the RAW event timestamp and are closed here.
--
-- THE DEFECT (measured on LIVE 2026-10-01 through the real worker, ROLLBACK probes)
--   update_planet_resources_until() correctly refuses to move a planet's clock BACKWARDS
--   (INVALID_RESOURCE_TIMESTAMP). That guard is correct and is NOT touched here.
--   These four call sites asked it to settle at an event timestamp that could already be behind:
--       resolve_attack_arrival     -> update_planet_resources_until(defender, arrives_at)
--       resolve_espionage_arrival  -> update_planet_resources_until(target,   arrives_at)
--       resolve_expedition_arrival -> update_planet_resources_until(origin,    arrives_at)
--       apply_attack_loot          -> update_planet_resources_until(defender, arrives_at)
--
--   Measured with an event 2 h in the past against a body already settled to now(), calling the
--   real worker entry point `process_fleet_movements()` (the body of the 1 s deuteria-fleet-worker):
--       ATTACK      -> OUTBOUND after FIVE consecutive passes; 0 battles; 0 ships returned
--       ESPIONAGE   -> OUTBOUND; 0 espionage_reports
--       EXPEDITION  -> OUTBOUND
--       TRANSPORT   -> COMPLETED   (control: already covered by 20260930241000)
--   process_fleet_movements downgrades every error to `raise warning 'FLEET_RESOLUTION_FAILED'`,
--   so nothing rolls back and nothing surfaces: the movement retries forever and the ships, already
--   debited at dispatch, are lost permanently. No retry budget, no self-heal, no operator surface.
--
--   Reachability is the ORDINARY event order, not an exotic race. The fleet worker runs every 1 s
--   while universe-heartbeat runs every minute and settles every planet to now(); any player action
--   on the body (start_building, cancel_building, load_fleet_cargo, the merchant, the UI's
--   sync_current_planet_resources) does the same. Any interleaving that settles the body to now()
--   between the arrival timestamp and the worker's next pass strands the movement permanently.
--
-- THE FIX
--   The SAME clamp already accepted in 20260930240000/241000, one per anchor:
--   settle at greatest(<event timestamp>, last_calculated_at).
--     * event in the FUTURE (the normal certified path) -> no-op, anchoring byte-identical;
--     * event behind -> no elapsed time left to credit, so settling at the body's own clock grants
--       ZERO extra production and lets the mission finish.
--
-- NOT CHANGED
--   * update_planet_resources_until and its INVALID_RESOURCE_TIMESTAMP guard.
--   * Costs, times, fuel, holding windows, combat, plunder caps, expedition rewards, espionage
--     reveal rules, and every function SIGNATURE, volatility, SECURITY and `SET search_path`:
--     the bodies are spliced out of pg_get_functiondef, never retyped.
--   * process_shipyard_queue_until / process_defense_queue_until keep the raw arrives_at: they only
--     filter `finishes_at <= p_until` and never settle resources, so they cannot raise.
--
-- EDIT METHOD
--   Anchored text splice over the COMPLETE pg_get_functiondef output, the same technique as
--   20261001010000_economic_sustainability_guard.sql. Every anchor is asserted to occur exactly
--   ONCE before the splice, so the edit can neither apply twice nor hit the wrong call site.
-- ---------------------------------------------------------------------------------------------

do $clamp$
declare
    v_src    text;
    v_def    text;
    v_before text;
    v_n      integer;
begin
    /* ============================ 1. resolve_attack_arrival ============================ */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'resolve_attack_arrival' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: resolve_attack_arrival not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until\(v_fleet\.destination_planet_id,v_fleet\.arrives_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: resolve_attack_arrival anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'resolve_attack_arrival' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def,
        'v_planet_participant_id uuid; v_unsupported integer; v_part record;',
        'v_planet_participant_id uuid; v_unsupported integer; v_part record; v_settle_at timestamptz;');

    v_def := replace(v_def,
        '  perform public.update_planet_resources_until(v_fleet.destination_planet_id,v_fleet.arrives_at);',
        E'  -- CLAMP 2026-10-01: see the header. A defender already settled past `arrives_at`\r\n'
     || E'  -- raised INVALID_RESOURCE_TIMESTAMP on every pass, stranding the attack in OUTBOUND.\r\n'
     || E'  select greatest(v_fleet.arrives_at, pr.last_calculated_at) into v_settle_at\r\n'
     || E'    from public.planet_resources pr where pr.planet_id = v_fleet.destination_planet_id;\r\n'
     || E'  perform public.update_planet_resources_until(v_fleet.destination_planet_id,\r\n'
     || E'    coalesce(v_settle_at, v_fleet.arrives_at));');

    execute v_def;

    /* ========================= 2. resolve_espionage_arrival ========================= */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'resolve_espionage_arrival' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: resolve_espionage_arrival not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until\(v_target\.id, v_fleet\.arrives_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: resolve_espionage_arrival anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'resolve_espionage_arrival' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def,
        '    v_returns_at timestamp with time zone;',
        '    v_returns_at timestamp with time zone; v_settle_at timestamptz;');

    v_def := replace(v_def,
        '    perform public.update_planet_resources_until(v_target.id, v_fleet.arrives_at);',
        E'    -- CLAMP 2026-10-01: same anchor as resolve_attack_arrival. A target already settled\r\n'
     || E'    -- past `arrives_at` raised forever, so the probe never produced a report.\r\n'
     || E'    select greatest(v_fleet.arrives_at, pr.last_calculated_at) into v_settle_at\r\n'
     || E'      from public.planet_resources pr where pr.planet_id = v_target.id;\r\n'
     || E'    perform public.update_planet_resources_until(v_target.id,\r\n'
     || E'      coalesce(v_settle_at, v_fleet.arrives_at));');

    execute v_def;

    /* ========================= 3. resolve_expedition_arrival ========================= */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'resolve_expedition_arrival' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: resolve_expedition_arrival not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until\(v_fleet\.origin_planet_id,v_fleet\.arrives_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: resolve_expedition_arrival anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'resolve_expedition_arrival' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def, 'v_existing_outcome text;',
                                'v_existing_outcome text;v_settle_at timestamptz;');

    v_def := replace(v_def,
        ' PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id,v_fleet.arrives_at);',
        E' -- CLAMP 2026-10-01: same anchor. An origin settled past `arrives_at` raised forever,\r\n'
     || E' -- so the expedition never resolved and its fleet stayed OUTBOUND with ships lost.\r\n'
     || E' SELECT greatest(v_fleet.arrives_at, pr.last_calculated_at) INTO v_settle_at\r\n'
     || E'   FROM public.planet_resources pr WHERE pr.planet_id=v_fleet.origin_planet_id;\r\n'
     || E' PERFORM public.update_planet_resources_until(v_fleet.origin_planet_id,\r\n'
     || E'   coalesce(v_settle_at,v_fleet.arrives_at));');

    execute v_def;

    /* ============================ 4. apply_attack_loot ============================ */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'apply_attack_loot' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'CLAMP: apply_attack_loot not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'update_planet_resources_until\(v_battle\.defender_planet_id, v_fleet\.arrives_at\)', 'g');
    if v_n <> 1 then
        raise exception 'CLAMP: apply_attack_loot anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'apply_attack_loot' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def, '  v_rows integer;', '  v_rows integer; v_settle_at timestamptz;');

    v_def := replace(v_def,
        '  perform public.update_planet_resources_until(v_battle.defender_planet_id, v_fleet.arrives_at);',
        E'  -- CLAMP 2026-10-01: same anchor as resolve_attack_arrival. Plunder is still the\r\n'
     || E'  -- certified 50% of the settled stock and the debit stays bounded by what was\r\n'
     || E'  -- credited, so nothing is duplicated; without this the loot leg raised on its own.\r\n'
     || E'  select greatest(v_fleet.arrives_at, pr.last_calculated_at) into v_settle_at\r\n'
     || E'    from public.planet_resources pr where pr.planet_id = v_battle.defender_planet_id;\r\n'
     || E'  perform public.update_planet_resources_until(v_battle.defender_planet_id,\r\n'
     || E'    coalesce(v_settle_at, v_fleet.arrives_at));');

    execute v_def;

    /* ===================== POSTCONDITIONS: fix present, guard intact ===================== */
    foreach v_src in array array[
        'resolve_attack_arrival','resolve_espionage_arrival',
        'resolve_expedition_arrival','apply_attack_loot']
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
         where p.proname = 'apply_attack_loot' and p.pronamespace = 'public'::regnamespace)
       <> 'TABLE(loot_metal numeric, loot_crystal numeric, loot_deuterium numeric, cargo_capacity numeric)' then
        raise exception 'POSTCONDITION FAILED: apply_attack_loot signature changed';
    end if;

    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'resolve_espionage_arrival' and p.pronamespace = 'public'::regnamespace)
       <> 'TABLE(fleet_id uuid, target_planet_id uuid, report_id uuid, status text, returns_at timestamp with time zone)' then
        raise exception 'POSTCONDITION FAILED: resolve_espionage_arrival signature changed';
    end if;

    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'resolve_attack_arrival' and p.pronamespace = 'public'::regnamespace)
       <> 'uuid' then
        raise exception 'POSTCONDITION FAILED: resolve_attack_arrival signature changed';
    end if;

    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'resolve_expedition_arrival' and p.pronamespace = 'public'::regnamespace)
       <> 'text' then
        raise exception 'POSTCONDITION FAILED: resolve_expedition_arrival signature changed';
    end if;

    -- security posture must be unchanged: these stay internal, never client-executable
    foreach v_src in array array['resolve_attack_arrival','apply_attack_loot']
    loop
        if has_function_privilege('authenticated', 'public.'||v_src||'(uuid)', 'EXECUTE') then
            raise exception 'POSTCONDITION FAILED: % became client-executable', v_src;
        end if;
        if has_function_privilege('anon', 'public.'||v_src||'(uuid)', 'EXECUTE') then
            raise exception 'POSTCONDITION FAILED: % became anon-executable', v_src;
        end if;
    end loop;
end;
$clamp$;