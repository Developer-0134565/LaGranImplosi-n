-- EXPEDITION RETURN: ambiguous column reference (42702) -- 2026-10-01
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `resolve_expedition_return` RETURNS TABLE(..., status text). The OUT parameter `status` is a
--   PL/pgSQL variable and `fleet_movements.status` is a column, so this statement was rejected with
--   ERROR 42702 "column reference is ambiguous" on EVERY execution -- a plan-time error, not a race:
--
--       UPDATE public.fleet_movements
--       SET metal = 0, crystal = 0, deuterium = 0, status = 'COMPLETED'
--       WHERE id = p_fleet_id AND status = 'RETURNING';
--
--   The caller is the fleet worker's RETURNING loop, whose per-fleet handler downgrades any error to
--   `raise warning 'FLEET_RESOLUTION_FAILED ...'` (rolls nothing back, surfaces nothing). So 100 % of
--   expedition returns were dead: the movement never left RETURNING, its ships -- already debited at
--   dispatch -- were destroyed, and `get_player_fleet_slots` counts every movement that is not
--   COMPLETED/CANCELLED, so each expedition permanently consumed a fleet slot.
--
--   LIVE evidence at audit time: EXPEDITION d79a0bd0-5aa4-4195-991d-363cda138353 had been RETURNING
--   with a returns_at 13 h in the past and 5 large_cargo on board; calling the deployed function on
--   it raised 42702. It auto-resolved within one tick once the fix landed.
--
-- THE FIX UNDER TEST (20261001070000)
--   Alias the update exactly like every sibling arrival resolver. The OUT parameter is deliberately
--   NOT renamed: `status` is part of this contract's published column list.
--
-- LIMITATION: sequential, single session, inside ROLLBACK.
begin;

drop table if exists t_exp_ret;
create temp table t_exp_ret(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid;
    v_fleet uuid;
    v_now timestamptz := now();
    v_status text; v_err text;
    v_res_before numeric; v_res_after numeric;
    v_ok boolean; v_fail integer := 0;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.created_at, p.id limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 60)
      on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 60);
    update public.planet_ships set quantity = 0 where planet_id = v_planet and ship_id = 'large_cargo';

    /* ---------------- 1. THE DEPLOYED BODY ---------------- */
    v_ok := (select p.prosrc from pg_proc p
              where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
            ilike '%WHERE fm.id = p_fleet_id AND fm.status = ''RETURNING''%';
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. the deployed resolver qualifies the predicate (fm.status), which is what removes the 42702');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := not exists (
        select 1 from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.prosrc ilike '%where id = p_fleet_id and status = ''RETURNING''%');
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '2. NO public function carries the broken shape any more (family guard for this exact defect)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select pg_get_function_result(p.oid) from pg_proc p
              where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
            = 'TABLE(fleet_id uuid, origin_planet_id uuid, delivered_metal numeric, delivered_crystal numeric, delivered_deuterium numeric, status text)';
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. the published result columns are unchanged: status was NOT renamed');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
/* ---------------- 2. THE REGRESSION: an expedition return completes ---------------- */
    perform public.update_planet_resources_until(v_planet, v_now);
    select coalesce(metal,0) + coalesce(crystal,0) into v_res_before
      from public.planet_resources where planet_id = v_planet;

    insert into public.fleet_movements(
        player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, returns_at, status,
        destination_galaxy, destination_system, destination_position,
        expedition_hold_seconds, fuel_consumed, metal, crystal, deuterium)
    values (v_player, v_planet, null, 'EXPEDITION',
            v_now - interval '6 hours', v_now - interval '5 hours', v_now - interval '4 hours', 'RETURNING',
            1, 1, 16, 3600, 0, 7000, 3000, 0)
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'large_cargo', 5);

    /* anti-vacuity: the origin clock is genuinely AHEAD of the return event, i.e. the clamped path */
    v_ok := (select pr.last_calculated_at > fm.returns_at
               from public.planet_resources pr, public.fleet_movements fm
              where pr.planet_id = v_planet and fm.id = v_fleet);
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. ANTI-VACUITY: the origin clock really is ahead of the return event (the clamped path)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform * from public.process_fleet_movements();
    select status into v_status from public.fleet_movements where id = v_fleet;
    v_ok := v_status = 'COMPLETED';
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. THE REGRESSION: an expedition return now COMPLETES through the real worker (status=%s)', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(sum(quantity),0) from public.planet_ships ps
              where ps.planet_id = v_planet and ps.ship_id = 'large_cargo') = 5;
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. the 5 large_cargo come home instead of being destroyed');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(metal,0) + coalesce(crystal,0) into v_res_after
      from public.planet_resources where planet_id = v_planet;
    v_ok := v_res_after - v_res_before = 10000;
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. the expedition reward is credited exactly once (%s -> %s, +10000 expected)',
             v_res_before, v_res_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(sum(metal),0) + coalesce(sum(crystal),0) + coalesce(sum(deuterium),0)
               from public.fleet_movements where id = v_fleet) = 0;
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. the movement is unloaded: its cargo fields are zeroed, so a replay cannot credit twice');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
/* ---------------- 3. EXACTLY ONCE ---------------- */
    v_err := null;
    begin
        perform * from public.resolve_expedition_return(v_fleet);
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is not null and position('Expedition must be RETURNING' in v_err) > 0;
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. closing it twice is refused by the existing guard (%s): the resolver is exactly-once',
             coalesce(v_err,'ACCEPTED')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(metal,0) + coalesce(crystal,0) into v_res_after
      from public.planet_resources where planet_id = v_planet;
    v_ok := v_res_after - v_res_before = 10000;
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. a replay credits nothing extra (origin still +10000 over the baseline: %s -> %s)',
             v_res_before, v_res_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------- 4. NOTHING ELSE MOVED ---------------- */
    v_ok := (select p.prosrc from pg_proc p
              where p.proname = 'resolve_expedition_return' and p.pronamespace = 'public'::regnamespace)
            ilike '%greatest(v_return_at, pr.last_calculated_at)%';
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '11. the settlement clamp of 20260930240000 is still in place');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := has_function_privilege('service_role', 'public.resolve_expedition_return(uuid)', 'EXECUTE')
        and not has_function_privilege('authenticated', 'public.resolve_expedition_return(uuid)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.resolve_expedition_return(uuid)', 'EXECUTE');
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. ACL unchanged: internal to the worker, never client-executable');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) = 4 from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname in ('resolve_transport_arrival','resolve_deploy_arrival',
                                  'resolve_colonize_arrival','resolve_espionage_arrival')
                and p.prosrc ilike '%fleet_movements%fm%');
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. the four sibling resolvers already aliased their table and were NOT modified');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* `recall_fleet` also updates fleet_movements WITHOUT an alias and it is safe: its OUT parameters
       are prefixed (out_status, out_motion...), so no OUT variable is ever named `status`. This is the
       contrast that explains why exactly one function in the corpus was affected. */
    v_ok := (select p.prosrc from pg_proc p
              where p.proname = 'recall_fleet' and p.pronamespace = 'public'::regnamespace)
            ilike '%set status = %RETURNING%'
        and not exists (select 1 from pg_proc p
                         where p.proname = 'recall_fleet' and p.pronamespace = 'public'::regnamespace
                           and p.proargnames @> array['status'])
        and (select pg_get_function_result(p.oid) from pg_proc p
              where p.proname = 'recall_fleet' and p.pronamespace = 'public'::regnamespace)
            ilike '%out_status text%';
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. recall_fleet is safe by construction: no OUT parameter is named status (out_* prefixed)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------- 5. RESIDUE ---------------- */
    v_ok := not exists (
        select 1 from public.fleet_movements
         where id = v_fleet and status in ('OUTBOUND','ARRIVED','HOLDING','RETURNING'));
    insert into t_exp_ret(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '15. the movement created by this fixture is not left mid-lifecycle (its slot is released)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise notice 'EXPEDITION RETURN FIXTURE: % failures', v_fail;
end $test$;

select orden, resultado, prueba from t_exp_ret order by orden;

rollback;