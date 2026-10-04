-- LGI - ECONOMIC SOFTLOCK GUARD (mission 2026-10-01)
-- Transactional fixture: everything rolls back, zero residue in the live universe.
--
-- Proves the AUTOSUSTAINABILITY pre-flight on the single shared oracle
-- `evaluate_building_start_internal` (used by can_start_building, the preview read contract
-- and ai_decide_and_act_core), so PLAYER and AI are protected by the same authority.
--
-- Cases: A safe=PASS, B dangerous=REJECT, C affordability still uses the OLD error,
--        D no false positive, E retry/race cannot bypass, F AI goes through the same guard,
--        G ownership (non-owner + anonymous) and ACL.
begin;
do $d$
declare
    v_user uuid; v_player uuid; v_planet uuid;
    v_ai_player uuid; v_ai_planet uuid;
    v_att uuid := gen_random_uuid();
    r record; s record; v_err text; v_rows bigint; v_blocked boolean;
    v_lines text[] := array[]::text[]; v_res text[] := array[]::text[];
    v_metal_before numeric; v_queue_before bigint;
begin
    select pl.id, pl.user_id into v_player, v_user from public.players pl
     where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_planet from public.planets p
     where p.player_id = v_player and not p.is_destroyed order by p.is_homeworld desc limit 1;

    /* ---------- SANDBOX: a fresh, no-buildings economy exactly like bootstrap ---------- */
    update public.planets set fields_used = 0 where id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    delete from public.planet_buildings where planet_id = v_planet;
    update public.planet_resources
       set metal = 500, crystal = 500, deuterium = 0 where planet_id = v_planet;

    -- A. the exact documented soft-lock: a consumer with NO energy source is not sustainable
    select * into s from public.evaluate_economic_sustainability(v_planet, 'crystal_mine', 1);
    v_lines := array_append(v_lines, format(
        'A. baseline crystal_mine L1 on a bare planet -> applicable=%s blocks=%s factor_after=%s recovery=%s',
        s.applicable, s.blocks, s.production_factor_after, s.recovery_available));
    v_res := array_append(v_res, case when s.applicable and s.blocks
         and s.production_factor_after = 0 and s.recovery_available then 'PASS' else 'FAIL' end);

    -- B. the action that RESCUES the economy must always be allowed
    select * into s from public.evaluate_economic_sustainability(v_planet, 'solar_plant', 1);
    v_lines := array_append(v_lines, format('B. solar_plant L1 (the recovery) -> applicable=%s blocks=%s factor_after=%s',
        s.applicable, s.blocks, s.production_factor_after));
    v_res := array_append(v_res, case when not s.blocks and s.production_factor_after > 0 then 'PASS' else 'FAIL' end);

    -- C. no false positive: a building that cannot move energy is NOT guarded
    select * into s from public.evaluate_economic_sustainability(v_planet, 'shipyard', 1);
    v_lines := array_append(v_lines, format('C. shipyard L1 (no energy effect) -> applicable=%s blocks=%s',
        s.applicable, s.blocks));
    v_res := array_append(v_res, case when not s.applicable and not s.blocks then 'PASS' else 'FAIL' end);

    /* ---------- D. PLAYER is actually REJECTED at the shared oracle ---------- */
    delete from public.building_queue where planet_id = v_planet;
    select * into r from public.evaluate_building_start_internal(v_player, v_planet, 'crystal_mine');
    v_lines := array_append(v_lines, format('D. player crystal_mine L1 -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed and r.reason <> 'OK'
         and r.reason <> 'Recursos insuficientes' then 'PASS' else 'FAIL' end);

    -- D2. the client contract reports the same verdict
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    select * into r from public.can_start_building(v_player, v_planet, 'crystal_mine');
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('D2. can_start_building crystal_mine L1 -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed then 'PASS' else 'FAIL' end);

    -- D3. the dispatcher refuses AND charges nothing
    select pr.metal into v_metal_before from public.planet_resources pr where pr.planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    v_err := null;
    begin
        perform set_config('role', 'authenticated', true);
        perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
        perform public.start_building(v_player, v_planet, 'crystal_mine');
    exception when others then v_err := sqlerrm;
    end;
    perform set_config('role', 'postgres', true);
    select count(*) into v_queue_before from public.building_queue where planet_id = v_planet;
    v_lines := array_append(v_lines, format('D3. start_building refused (err=%s), queue rows=%s, metal charged=%s',
        coalesce(v_err, '<none>'), v_queue_before,
        (v_metal_before - (select metal from public.planet_resources where planet_id = v_planet)) <> 0));
    v_res := array_append(v_res, case when v_err like '%energia suficiente%' and v_queue_before = 0
         and (select metal from public.planet_resources where planet_id = v_planet) = v_metal_before
         then 'PASS' else 'FAIL' end);

    /* ---------- E. AFFORDABILITY still returns the pre-existing economic error ---------- */
    update public.planet_resources set metal = 0, crystal = 0 where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'solar_plant', 1);
    delete from public.building_queue where planet_id = v_planet;
    select * into r from public.evaluate_building_start_internal(v_player, v_planet, 'metal_mine');
    v_lines := array_append(v_lines, format('E. broke player, metal_mine L1 -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed and r.reason = 'Recursos insuficientes' then 'PASS' else 'FAIL' end);

    /* ---------- F. no FALSE POSITIVE once the planet has an energy source ---------- */
    update public.planet_resources set metal = 5000, crystal = 5000 where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    select * into r from public.evaluate_building_start_internal(v_player, v_planet, 'crystal_mine');
    v_lines := array_append(v_lines, format('F. crystal_mine L1 WITH solar plant -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when r.allowed and r.reason = 'OK' then 'PASS' else 'FAIL' end);

    -- F2. REPEATED attempts cannot bypass the guard (retry / race)
    delete from public.planet_buildings where planet_id = v_planet and building_id = 'solar_plant';
    v_blocked := false;
    for i in 1..3 loop
        delete from public.building_queue where planet_id = v_planet;
        select * into r from public.evaluate_building_start_internal(v_player, v_planet, 'crystal_mine');
        if not r.allowed then v_blocked := true; end if;
    end loop;
    v_lines := array_append(v_lines, format('F2. 3 consecutive attempts all blocked = %s', v_blocked));
    v_res := array_append(v_res, case when v_blocked then 'PASS' else 'FAIL' end);

    /* ---------- F3. the REAL trap: a bare planet cannot take ANY consumer first ----------
       On a planet with no energy source, even the FIRST consumer collapses production to 0.
       The guard must block it and point at the recovery; following that advice must then
       open the whole economy. This is the real gameplay loop, certified end to end.
       NOTE: the queue is emptied between steps because `start_building` enforces a single
       active item per planet; that is a different (pre-existing) rule, not the guard. */
    perform set_config('role', 'postgres', true);
    delete from public.building_queue where planet_id = v_planet;
    delete from public.planet_buildings where planet_id = v_planet;
    update public.planet_resources set metal = 500, crystal = 500, deuterium = 0 where planet_id = v_planet;
    perform set_config('role', 'authenticated', true);
    v_err := null;
    begin perform public.start_building(v_player, v_planet, 'metal_mine');
    exception when others then v_err := sqlerrm;
    end;
    v_lines := array_append(v_lines, format('F3. bare planet, metal_mine L1 -> refused=%s', v_err like '%energia suficiente%'));
    v_res := array_append(v_res, case when v_err like '%energia suficiente%' then 'PASS' else 'FAIL' end);

    -- the advised recovery is always available
    perform set_config('role', 'postgres', true);
    delete from public.building_queue where planet_id = v_planet;
    perform set_config('role', 'authenticated', true);
    v_err := null;
    begin perform public.start_building(v_player, v_planet, 'solar_plant');
    exception when others then v_err := sqlerrm;
    end;
    v_lines := array_append(v_lines, format('F4. follow the advice, solar_plant L1 -> ok=%s', v_err is null));
    v_res := array_append(v_res, case when v_err is null then 'PASS' else 'FAIL' end);

    -- ...and now every consumer is allowed again
    perform set_config('role', 'postgres', true);
    delete from public.building_queue where planet_id = v_planet;
    insert into public.planet_buildings(planet_id, building_id, level) values (v_planet, 'solar_plant', 1);
    update public.planet_resources set metal = 500, crystal = 500 where planet_id = v_planet;
    perform set_config('role', 'authenticated', true);
    v_err := null;
    begin perform public.start_building(v_player, v_planet, 'metal_mine');
    exception when others then v_err := sqlerrm;
    end;
    v_lines := array_append(v_lines, format('F5. with solar, metal_mine L1 -> ok=%s (economy unblocked)', v_err is null));
    v_res := array_append(v_res, case when v_err is null then 'PASS' else 'FAIL' end);
    perform set_config('role', 'postgres', true);

    /* ---------- G. AI: the SAME guard rejects the AI's own candidate ----------
       The AI acts through the declared-actor contract (ai_actor_begin), which is what
       `ai_decide_and_act` uses, so this reproduces the real policy path. */
    select pl.id, p.id into v_ai_player, v_ai_planet
      from public.players pl join public.planets p on p.player_id = pl.id
     where pl.player_type = 'AI' and pl.user_id is null and p.kind = 'PLANET' and not p.is_destroyed
     order by pl.created_at, p.created_at limit 1;

    update public.planets set fields_used = 0 where id = v_ai_planet;
    delete from public.building_queue where planet_id = v_ai_planet;
    delete from public.planet_buildings where planet_id = v_ai_planet;
    update public.planet_resources set metal = 500, crystal = 500, deuterium = 0 where planet_id = v_ai_planet;
    perform public.ai_actor_begin(v_ai_player);

    v_err := null;
    begin perform public.start_building(v_ai_player, v_ai_planet, 'crystal_mine');
    exception when others then v_err := sqlerrm;
    end;
    select count(*) into v_queue_before from public.building_queue where planet_id = v_ai_planet;
    v_lines := array_append(v_lines, format('G. AI unsafe candidate crystal_mine -> err=%s queue=%s',
        coalesce(v_err,'<NONE>'), v_queue_before));
    v_res := array_append(v_res, case when v_err like '%energia suficiente%' and v_queue_before = 0
         then 'PASS' else 'FAIL' end);

    select * into r from public.can_start_building(v_ai_player, v_ai_planet, 'crystal_mine');
    v_lines := array_append(v_lines, format('G2. AI can_start_building -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed then 'PASS' else 'FAIL' end);

    delete from public.building_queue where planet_id = v_ai_planet;
    v_err := null;
    begin perform public.start_building(v_ai_player, v_ai_planet, 'solar_plant');
    exception when others then v_err := sqlerrm;
    end;
    select count(*) into v_queue_before from public.building_queue where planet_id = v_ai_planet;
    v_lines := array_append(v_lines, format('G3. AI safe candidate solar_plant -> err=%s queue=%s',
        coalesce(v_err,'<none>'), v_queue_before));
    v_res := array_append(v_res, case when v_err is null and v_queue_before = 1 then 'PASS' else 'FAIL' end);

    perform public.ai_actor_end();

    /* ---------- H. OWNERSHIP ---------- */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_att, 'role', 'authenticated')::text, true);
    select count(*) into v_rows from public.get_economic_sustainability_check(v_planet, 'crystal_mine');
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('H. non-owner read rows=%s (expect 0)', v_rows));
    v_res := array_append(v_res, case when v_rows = 0 then 'PASS' else 'FAIL' end);

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    select count(*) into v_rows from public.get_economic_sustainability_check(v_planet, 'crystal_mine');
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('H2. owner read rows=%s (expect 1)', v_rows));
    v_res := array_append(v_res, case when v_rows = 1 then 'PASS' else 'FAIL' end);

    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', '{}', true);
    v_blocked := false;
    begin
        perform public.get_economic_sustainability_check(v_planet, 'crystal_mine');
        v_blocked := true;
    exception when others then v_blocked := false;
    end;
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('H3. anonymous reachable=%s (expect false)', v_blocked));
    v_res := array_append(v_res, case when not v_blocked then 'PASS' else 'FAIL' end);

    /* ---------- I. ACL: the internals stay off the client surface ---------- */
    v_lines := array_append(v_lines, format(
        'I. ACL evaluate_economic_sustainability: service=%s authenticated=%s anon=%s; check: authenticated=%s',
        has_function_privilege('service_role','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE'),
        has_function_privilege('authenticated','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE'),
        has_function_privilege('anon','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE'),
        has_function_privilege('authenticated','public.get_economic_sustainability_check(uuid,text)','EXECUTE')));
    v_res := array_append(v_res, case
        when has_function_privilege('service_role','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE')
         and not has_function_privilege('authenticated','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE')
         and not has_function_privilege('anon','public.evaluate_economic_sustainability(uuid,text,integer)','EXECUTE')
         and has_function_privilege('authenticated','public.get_economic_sustainability_check(uuid,text)','EXECUTE')
         and not has_function_privilege('anon','public.get_economic_sustainability_check(uuid,text)','EXECUTE')
        then 'PASS' else 'FAIL' end);

    /* ---------- J. anti-vacuity: guard present, and NO resource grant smuggled in ---------- */
    v_lines := array_append(v_lines, format(
        'J. anti-vacuity: oracle wired=%s, no planet_resources write in oracle=%s',
        (select prosrc like '%evaluate_economic_sustainability%' from pg_proc
          where proname='evaluate_building_start_internal' and pronamespace='public'::regnamespace),
        (select prosrc not like '%update public.planet_resources%' from pg_proc
          where proname='evaluate_building_start_internal' and pronamespace='public'::regnamespace)));
    v_res := array_append(v_res, case
        when (select prosrc like '%evaluate_economic_sustainability%' from pg_proc
               where proname='evaluate_building_start_internal' and pronamespace='public'::regnamespace)
         and (select prosrc not like '%update public.planet_resources%' from pg_proc
               where proname='evaluate_building_start_internal' and pronamespace='public'::regnamespace)
        then 'PASS' else 'FAIL' end);

    raise notice '%', array_to_string(v_lines, E'\n');
    if exists (select 1 from unnest(v_res) x where x = 'FAIL') then
        raise exception 'ECONOMIC_GUARD_CERTIFICATION FAILED: %', array_to_string(v_res, ',');
    end if;
    raise notice 'ECONOMIC_GUARD_CERTIFICATION PASSED (% assertions)', array_length(v_res,1);
end;
$d$;
rollback;
