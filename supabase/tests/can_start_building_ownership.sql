-- LGI - can_start_building ownership contract (migration 20260926240000)
-- Transactional fixture: everything is rolled back, zero residue in the live universe.
-- Reproduces the oracle that existed BEFORE the fix (owner t/OK level 2, foreign t/OK level 0, anon t/OK)
-- and proves the certified behaviour AFTER it.
begin;
drop table if exists t_csb;
create temp table t_csb(resultado text, prueba text);
do $d$
declare
    v_user uuid; v_player uuid; v_planet uuid; v_building text; v_att uuid := gen_random_uuid();
    v_ai uuid; v_ai_planet uuid; v_ai_other uuid; r record; r_ai record; r_direct record;
    v_err text; v_qty integer; v_blocked boolean; v_lines text[] := array[]::text[]; v_res text[] := array[]::text[]; v_slot text;
begin
    select pl.id, pl.user_id into v_player, v_user from public.players pl
     where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_planet from public.planets p where p.player_id = v_player and not p.is_destroyed
     order by p.is_homeworld desc limit 1;
    select pb.building_id into v_building from public.planet_buildings pb
     where pb.planet_id = v_planet order by pb.level desc limit 1;
    v_building := coalesce(v_building, 'metal_mine');
    select pl.id, p.id into v_ai, v_ai_planet
      from public.players pl join public.planets p on p.player_id = pl.id
     where pl.player_type = 'AI' and pl.user_id is null and p.kind = 'PLANET' and not p.is_destroyed
     order by pl.created_at, p.created_at limit 1;
    select pl.id into v_ai_other from public.players pl
     where pl.player_type = 'AI' and pl.user_id is null and pl.id <> v_ai limit 1;

    /* A. owner keeps the full, authoritative answer */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    select * into r from public.can_start_building(v_player, v_planet, v_building);
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('A. owner -> allowed=%s reason=%s level=%s cost_m=%s avail_m=%s',
        r.allowed, r.reason, r.current_level, r.cost_metal, r.available_metal));
    v_res := array_append(v_res, case when r.allowed and r.reason = 'OK' and r.current_level > 0 and r.available_metal > 0 then 'PASS' else 'FAIL' end);

    /* B. foreign authenticated actor: blocked, and no private condition leaks */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_att, 'role', 'authenticated')::text, true);
    select * into r from public.can_start_building(v_player, v_planet, v_building);
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('B. foreign actor -> allowed=%s reason=%s level=%s target=%s cost_m=%s avail_m=%s',
        r.allowed, r.reason, r.current_level, r.target_level, r.cost_metal, r.available_metal));
    v_res := array_append(v_res, case when not r.allowed and r.reason = 'PLAYER_NOT_OWNED' and r.current_level = 0
        and r.target_level = 0 and coalesce(r.cost_metal,0) = 0 and coalesce(r.available_metal,0) = 0 then 'PASS' else 'FAIL' end);

    /* B2. anonymous actor */
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', '{}', true);
    select * into r from public.can_start_building(v_player, v_planet, v_building);
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('B2. anonymous -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed and r.reason = 'AUTHENTICATION_REQUIRED' then 'PASS' else 'FAIL' end);

    /* C. the owner can still mutate */
    delete from public.building_queue where planet_id = v_planet;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    v_err := null;
    begin perform public.start_building(v_player, v_planet, 'metal_mine');
    exception when others then v_err := sqlerrm; end;
    perform set_config('role', 'postgres', true);
    select count(*) into v_qty from public.building_queue where planet_id = v_planet;
    v_lines := array_append(v_lines, format('C. owner start_building -> queue rows=%s err=%s', v_qty, coalesce(v_err,'(none)')));
    v_res := array_append(v_res, case when v_qty = 1 and v_err is null then 'PASS' else 'FAIL' end);
    delete from public.building_queue where planet_id = v_planet;

    /* D. a foreign actor still cannot mutate */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_att, 'role', 'authenticated')::text, true);
    v_blocked := false; v_err := null;
    begin perform public.start_building(v_player, v_planet, 'metal_mine');
    exception when others then v_blocked := true; v_err := sqlerrm; end;
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('D. foreign start_building -> blocked=%s err=%s', v_blocked, coalesce(v_err,'-')));
    v_res := array_append(v_res, case when v_blocked then 'PASS' else 'FAIL' end);

    /* E. declared AI actor keeps its contract (gate passed, business answer) */
    perform set_config('role', 'service_role', true);
    perform set_config('request.jwt.claims', '{}', true);
    perform set_config('lgi.ai_worker', 'on', true);
    perform set_config('lgi.ai_player', v_ai::text, true);
    select * into r_ai from public.can_start_building(v_ai, v_ai_planet, 'metal_mine');
    select * into r_direct from public.evaluate_building_start_internal(v_ai, v_ai_planet, 'metal_mine');
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('E. declared AI actor -> allowed=%s reason=%s', r_ai.allowed, r_ai.reason));
    v_res := array_append(v_res, case when r_ai.reason not in ('AUTHENTICATION_REQUIRED','PLAYER_NOT_OWNED') then 'PASS' else 'FAIL' end);
    v_res := array_append(v_res, case when r_ai.allowed is not distinct from r_direct.allowed
        and r_ai.reason is not distinct from r_direct.reason then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('E2. AI path identical to the preserved evaluator -> allowed=%s reason=%s',
        r_direct.allowed, r_direct.reason));

    /* E3. an AI actor aiming at somebody else stays blocked */
    perform set_config('role', 'service_role', true);
    perform set_config('lgi.ai_worker', 'on', true);
    perform set_config('lgi.ai_player', coalesce(v_ai_other, gen_random_uuid())::text, true);
    select * into r from public.can_start_building(v_ai, v_ai_planet, 'metal_mine');
    perform set_config('role', 'postgres', true);
    v_lines := array_append(v_lines, format('E3. AI actor targeting another player -> allowed=%s reason=%s', r.allowed, r.reason));
    v_res := array_append(v_res, case when not r.allowed and r.reason = 'AUTHENTICATION_REQUIRED' then 'PASS' else 'FAIL' end);
    perform set_config('lgi.ai_worker', 'off', true);
    perform set_config('lgi.ai_player', '', true);

    /* F. the internal evaluator is not reachable from the client */
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    v_blocked := false;
    begin perform 1 from public.evaluate_building_start_internal(v_player, v_planet, v_building);
    exception when others then v_blocked := true; end;
    perform set_config('role', 'postgres', true);
    v_res := array_append(v_res, case when v_blocked then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, 'F. internal evaluator as authenticated -> permission denied');

    /* G. contract preserved and siblings untouched */
    select case when p.prosecdef then 'DEFINER' else 'INVOKER' end into v_err from pg_proc p
     where p.pronamespace='public'::regnamespace and p.proname='can_start_building';
    select count(*) into v_qty from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='can_start_building'
      and has_function_privilege('anon', p.oid, 'execute') and has_function_privilege('authenticated', p.oid, 'execute')
      and has_function_privilege('service_role', p.oid, 'execute');
    v_res := array_append(v_res, case when v_err = 'DEFINER' and v_qty = 1 then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('G. SECURITY %s ; anon+authenticated+service_role execute=%s', v_err, v_qty));
    v_res := array_append(v_res, case when (select count(*) from pg_trigger t
        where t.tgfoid = 'public.enforce_player_write_access()'::regprocedure) >= 1 then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('G2. enforce_player_write_access still attached to %s protected tables',
        (select count(*) from pg_trigger t where t.tgfoid = 'public.enforce_player_write_access()'::regprocedure)));

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_att, 'role', 'authenticated')::text, true);
    select i.reason into v_err from public.can_start_demolition(v_player, v_planet, v_building) i;
    perform set_config('role', 'postgres', true);
    v_res := array_append(v_res, case when v_err = 'PLAYER_NOT_OWNED_BY_AUTH_USER' then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('G3. can_start_demolition (sibling, untouched) -> %s', coalesce(v_err,'(null)')));

    for v_qty in 1..array_length(v_res, 1) loop
        insert into t_csb values (v_res[v_qty], v_lines[v_qty]);
    end loop;
end;
$d$;
select case when count(*) filter (where resultado = 'FAIL') = 0 and count(*) >= 11 then 'PASS' else 'FAIL' end as final,
       count(*) as assertions, count(*) filter (where resultado = 'PASS') as passed from t_csb;
select resultado, prueba from t_csb order by prueba;
drop table if exists t_csb;
rollback;