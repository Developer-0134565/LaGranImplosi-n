-- RECYCLE STUCK-STATE: a recycler whose debris field was emptied by ANOTHER recycler before it
-- arrived lost its ships and its fleet slot forever.
-- ---------------------------------------------------------------------------------------------
-- DECISION GATE -- the semantics were READ from the upstream contract, not invented:
--
--   OGameX `main` @ 2649076, app/GameMissions/RecycleMission.php :: processArrival()
--       $resourcesToHarvest = $debrisField->getResources();            // may be 0 / 0
--       $resourcesHarvested  = LootService::distributeLoot($resourcesToHarvest, $total_cargo_capacity);
--       if ($resourcesHarvested->any()) { ...deduct... }
--       $mission->processed = 1; $mission->save();
--       $this->startReturn($mission, $totalResources, $units);          // ALWAYS returns
--
--   => Harvesting zero is a legal, expected outcome and the fleet ALWAYS flies home. LGI already
--      applies the same rule to the structurally identical case: `resolve_colonize_arrival`
--      ("A late worker must not extend the flight") turns a COLONIZE whose coordinate was taken
--      in the meantime into RETURNING and keeps its cargo. The RECYCLE arm was the one arrival
--      resolver without that guard.
--
-- THE DEFECT (measured on LIVE 2026-10-01, ROLLBACK probes through the real worker)
--   `collect_debris` refuses a target that has nothing left:
--       RAISE EXCEPTION 'No debris field at [%:%:%] in universe %'   -- row gone: the first recycler
--                                                                       emptied it and this same
--                                                                       function DELETEs the row
--       RAISE EXCEPTION 'Debris field is empty'                     -- row present, metal=crystal=0
--   `process_fleet_movements` downgrades ANY per-fleet error to
--       exception when others then raise warning 'FLEET_RESOLUTION_FAILED ...'
--   A WARNING rolls nothing back and surfaces nothing, so the movement retried forever:
--
--     A. field EMPTIED (0/0) by another recycler -> status after worker = OUTBOUND
--     B. field DELETED by another recycler      -> status after worker = OUTBOUND
--
--   Impact, all permanent and irreversible:
--     * the recycler ships were debited from the origin at dispatch and are destroyed;
--     * the movement stays OUTBOUND forever, and `get_player_fleet_slots` counts every movement
--       whose status is not in ('COMPLETED','CANCELLED'), so the player loses one fleet slot FOREVER
--       (a player with computer_technology 0 has exactly 1 slot => total fleet lock).
--
--   Reachability is ORDINARY, not exotic: the RECYCLE target is chosen server-side by
--   `start_fleet_mixed` as "the nearest field with (metal>0 OR crystal>0)" and is NOT reserved, so
--   two recyclers dispatched in the same window -- by the same player or by two players of the same
--   universe -- are aimed at the same field. The first arrival drains it (capacity >= remainder, the
--   common case) and `collect_debris` deletes the row; the second arrival is the stuck one.
--   This is the same "event arrived after its precondition evaporated" family that 20260930240000 /
--   20260930241000 / 20261001030000 / 20261001040000 closed for the clock anchors.
--
-- THE FIX (one call site, one mission)
--   In the RECYCLE branch of `process_fleet_movements` only:
--     * absorb EXACTLY two outcomes -- 'Debris field is empty' and 'No debris field at%' -- and treat
--       them as "collected 0";
--     * every other error is re-raised unchanged, so a genuine defect (e.g. 'Fleet % contains no
--       Recycler') stays observable through FLEET_RESOLUTION_FAILED exactly as certified;
--     * the movement then follows the ALREADY EXISTING success path: RETURNING with
--       returns_at = arrives_at + (arrives_at - started_at), i.e. the original scheduled timeline.
--
-- NOT CHANGED
--   * `collect_debris` (body untouched, md5-verified in the postconditions): the collection
--     arithmetic, the capacity split, the row deletion when a field is exhausted, and BOTH refusals
--     remain for every other caller.
--   * `calculate_recycler_capacity`, `start_fleet_mixed`: the DISPATCH-side contract is unchanged --
--     it still refuses 'No debris field available for RECYCLE' when no non-empty field exists, still
--     targets the nearest field, still admits recyclers only, still debits fuel+ships atomically.
--     No dispatch path was weakened.
--   * `get_recyclable_debris_status` (the UI hint) and `get_player_fleet_slots`.
--   * Balances: no cost, time, capacity, percentage, expiry or loot rule is introduced.
--   * Function SIGNATURE, volatility, SECURITY and `SET search_path` of `process_fleet_movements`
--     (the body is spliced out of pg_get_functiondef, never retyped), and the three
--     FLEET_RESOLUTION_FAILED handlers.
--
-- EDIT METHOD
--   Anchored text splice over the COMPLETE pg_get_functiondef output, the same technique as
--   20261001010000 / 20261001030000 / 20261001040000. Each anchor is asserted to occur exactly ONCE
--   before the splice.
do $recycle$
declare
    v_src text; v_def text; v_n integer;
begin
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'RECYCLE: process_fleet_movements not found'; end if;

    select count(*) into v_n from regexp_matches(v_src, 'v_recycle record;', 'g');
    if v_n <> 1 then
        raise exception 'RECYCLE: declaration anchor occurs % times (expected 1)', v_n;
    end if;

    select count(*) into v_n from regexp_matches(v_src,
        'collect_debris\(v\.id,v\.destination_galaxy,v\.destination_system,v\.destination_position\);', 'g');
    if v_n <> 1 then
        raise exception 'RECYCLE: call anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def, '  v_recycle record;'||chr(10),
                                '  v_recycle record;'||chr(10)
                             || '  v_recycle_metal numeric := 0;'||chr(10)
                             || '  v_recycle_crystal numeric := 0;'||chr(10));

    v_def := replace(v_def,
        '      select * into v_recycle'||chr(10)
     || '      from public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);'||chr(10)
     || chr(10)
     || '      update public.fleet_movements'||chr(10)
     || '      set metal=coalesce(v_recycle.out_metal_collected,0),'||chr(10)
     || '          crystal=coalesce(v_recycle.out_crystal_collected,0),',

        '-- GAP 2026-10-01: see the header. A recycler whose field was emptied by ANOTHER'||chr(10)
     || '      -- recycler before it arrived raised inside collect_debris, and this loop''s per-fleet'||chr(10)
     || '      -- handler downgrades any error to a WARNING, so the movement retried forever:'||chr(10)
     || '      -- ships debited at dispatch destroyed and the fleet slot consumed forever.'||chr(10)
     || '      -- OGameX RecycleMission::processArrival harvests whatever the field holds (zero is a'||chr(10)
     || '      -- legal outcome) and ALWAYS calls startReturn(), so collecting 0 and coming home is'||chr(10)
     || '      -- the upstream contract, exactly like the guard resolve_colonize_arrival already has.'||chr(10)
     || '      -- ONLY those two "nothing left to harvest" outcomes are absorbed; every other error is'||chr(10)
     || '      -- re-raised unchanged so a genuine defect stays visible in the worker warning.'||chr(10)
     || '      v_recycle_metal := 0;'||chr(10)
     || '      v_recycle_crystal := 0;'||chr(10)
     || '      begin'||chr(10)
     || '        select * into v_recycle'||chr(10)
     || '        from public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);'||chr(10)
     || '        v_recycle_metal := coalesce(v_recycle.out_metal_collected,0);'||chr(10)
     || '        v_recycle_crystal := coalesce(v_recycle.out_crystal_collected,0);'||chr(10)
     || '      exception'||chr(10)
     || '        when others then'||chr(10)
     || '          if sqlerrm like ''Debris field is empty%'''||chr(10)
     || '             or sqlerrm like ''No debris field at%'' then'||chr(10)
     || '            null;'||chr(10)
     || '          else'||chr(10)
     || '            raise;'||chr(10)
     || '          end if;'||chr(10)
     || '      end;'||chr(10)
     || chr(10)
     || '      update public.fleet_movements'||chr(10)
     || '      set metal=v_recycle_metal,'||chr(10)
     || '          crystal=v_recycle_crystal,');

    execute v_def;
/* ================= POSTCONDITIONS: fix present, nothing else moved ================= */

    -- 1. the absorption handler is deployed
    if (select p.prosrc from pg_proc p
         where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace)
       not ilike '%No debris field at%' then
        raise exception 'POSTCONDITION FAILED: the RECYCLE empty-field handler is not deployed';
    end if;

    -- 2. the RECYCLE arrival guard and return transition survive the splice
    if (select p.prosrc from pg_proc p
         where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace)
       not ilike '%status=''RETURNING'',%returns_at=v.arrives_at+v_duration%' then
        raise exception 'POSTCONDITION FAILED: the RECYCLE return transition was altered';
    end if;

    -- 3. the three per-fleet isolation handlers are untouched
    if (select (length(p.prosrc) - length(replace(p.prosrc, 'FLEET_RESOLUTION_FAILED', '')))
                   / length('FLEET_RESOLUTION_FAILED')
          from pg_proc p
         where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace) <> 3 then
        raise exception 'POSTCONDITION FAILED: the per-fleet exception handlers changed';
    end if;

    -- 4. collect_debris is byte-identical: the refusals and the arithmetic are untouched
    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       <> '4e63662301c7d89b3b07b720ec4d7627' then
        raise exception 'POSTCONDITION FAILED: collect_debris was modified';
    end if;

    -- 5. the DISPATCH contract is untouched
    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'start_fleet_mixed' and p.pronamespace = 'public'::regnamespace)
       <> '611d107dacf0e3869d162d11fb63fcf1' then
        raise exception 'POSTCONDITION FAILED: start_fleet_mixed was modified';
    end if;

    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'calculate_recycler_capacity' and p.pronamespace = 'public'::regnamespace)
       <> '235910c7dd6a3b31ec7ee712af2d24f1' then
        raise exception 'POSTCONDITION FAILED: calculate_recycler_capacity was modified';
    end if;

    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'get_player_fleet_slots' and p.pronamespace = 'public'::regnamespace)
       <> '119b1100d6b13b40428545c5ebad3cf4' then
        raise exception 'POSTCONDITION FAILED: get_player_fleet_slots was modified';
    end if;

    -- 6. signature unchanged
    if (select pg_get_function_result(p.oid) from pg_proc p
         where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace)
       not ilike '%new_status text%' then
        raise exception 'POSTCONDITION FAILED: process_fleet_movements signature changed';
    end if;

    -- 7. security posture unchanged: the worker is never client-executable
    if has_function_privilege('authenticated', 'public.process_fleet_movements()', 'EXECUTE')
       or has_function_privilege('anon', 'public.process_fleet_movements()', 'EXECUTE') then
        raise exception 'POSTCONDITION FAILED: process_fleet_movements became client-executable';
    end if;
end;
$recycle$;
-- ---------------------------------------------------------------------------------------------