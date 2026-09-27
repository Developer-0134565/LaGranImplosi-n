-- LGI - fleet worker contract fixture (H4 of the 2026-09-26 audit)
-- Transactional: BEGIN ... ROLLBACK, zero residue. Proves that process_fleet_movements drives a real
-- TRANSPORT from dispatch to COMPLETED through its own loops, and that it is idempotent.
--
-- Two harness rules learned while closing H4 (both are engine validations, not worker defects):
--   * the resource ledger must stay behind the fleet timestamps: update_planet_resources_until[_raw]
--     raises INVALID_RESOURCE_TIMESTAMP (P0001) when asked to write a planet cost/benefit *before*
--     planet_resources.last_calculated_at, so the fixture moves the ledger back before time-travelling;
--   * never set the fleet to ARRIVED by hand: the worker itself performs OUTBOUND -> ARRIVED, and a
--     hand-made ARRIVED row is no longer in its OUTBOUND loop (that is why an earlier harness saw nothing).
begin;
drop table if exists t_fwc;
create temp table t_fwc(resultado text, prueba text);
do $d$
declare
    v_user uuid; v_player uuid; v_planet uuid; v_dest uuid; v_ship text := 'light_fighter';
    v_err text; v_lines text[] := array[]::text[]; v_res text[] := array[]::text[];
    v_f uuid; v_status text; v_rows integer; v_ships bigint; v_msgs integer; v_dest_metal numeric;
begin
    select pl.id, pl.user_id into v_player, v_user from public.players pl
     where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_planet from public.planets p where p.player_id = v_player and not p.is_destroyed
     order by p.is_homeworld desc limit 1;
    select p.id into v_dest from public.planets p where p.id <> v_planet and not p.is_destroyed
       and p.kind = 'PLANET' order by p.created_at limit 1;

    update public.planet_resources set last_calculated_at = now() - interval '4 hours'
     where planet_id in (v_planet, v_dest);
    insert into public.planet_ships (planet_id, ship_id, quantity) values (v_planet, v_ship, 6)
    on conflict (planet_id, ship_id) do update set quantity = 6;
    update public.planet_resources set deuterium = greatest(deuterium, 2000000) where planet_id = v_planet;
    insert into public.player_research (player_id, research_id, level) values (v_player, 'computer_technology', 5)
    on conflict (player_id, research_id) do update set level = 5;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    select f.fleet_id into v_f from public.start_fleet(v_player, v_planet, v_dest, v_ship, 2, 'TRANSPORT') f;
    perform set_config('role', 'postgres', true);

    select status into v_status from public.fleet_movements where id = v_f;
    select quantity into v_ships from public.planet_ships where planet_id = v_planet and ship_id = v_ship;
    v_lines := array_append(v_lines, format('0. dispatch TRANSPORT -> status=%s ships at origin=%s (6-2)', v_status, v_ships));
    v_res := array_append(v_res, case when v_status = 'OUTBOUND' and v_ships = 4 then 'PASS' else 'FAIL' end);

    /* arrival leg: the worker must move OUTBOUND -> ARRIVED -> RETURNING */
    update public.planet_resources set last_calculated_at = now() - interval '4 hours' where planet_id = v_planet;
    update public.fleet_movements set started_at = now() - interval '2 hours', arrives_at = now() - interval '1 minute'
     where id = v_f;
    begin select count(*) into v_rows from public.process_fleet_movements();
    exception when others then v_rows := -1; v_err := sqlstate || ' ' || sqlerrm; end;
    select status into v_status from public.fleet_movements where id = v_f;
    v_lines := array_append(v_lines, format('1. worker ARRIVAL pass -> rows=%s status=%s %s', v_rows, v_status, coalesce('ERR:'||v_err,'')));
    v_res := array_append(v_res, case when v_rows = 1 and v_status = 'RETURNING' then 'PASS' else 'FAIL' end);

    /* return leg: RETURNING -> COMPLETED and the ships come home */
    update public.planet_resources set last_calculated_at = now() - interval '4 hours' where planet_id in (v_planet, v_dest);
    update public.fleet_movements set started_at = now() - interval '4 hours', returns_at = now() - interval '1 minute'
     where id = v_f;
    begin select count(*) into v_rows from public.process_fleet_movements();
    exception when others then v_rows := -1; v_err := sqlstate || ' ' || sqlerrm; end;
    select status into v_status from public.fleet_movements where id = v_f;
    select quantity into v_ships from public.planet_ships where planet_id = v_planet and ship_id = v_ship;
    v_lines := array_append(v_lines, format('2. worker RETURN pass -> rows=%s status=%s ships at origin=%s %s',
        v_rows, coalesce(v_status,'(completed)'), v_ships, coalesce('ERR:'||v_err,'')));
    v_res := array_append(v_res, case when v_ships = 6 and (v_status = 'COMPLETED' or v_status is null) then 'PASS' else 'FAIL' end);

    /* messages produced by the transitions, with dedupe keys */
    select count(*) into v_msgs from public.player_messages where dedupe_key like 'fleet%';
    v_lines := array_append(v_lines, format('3. fleet messages produced (dedupe_key fleet*) = %s', v_msgs));
    v_res := array_append(v_res, case when v_msgs >= 1 then 'PASS' else 'FAIL' end);

    /* idempotence: two more passes must change nothing */
    begin select count(*) into v_rows from public.process_fleet_movements();
    exception when others then v_rows := -1; v_err := sqlstate || ' ' || sqlerrm; end;
    begin select count(*) into v_ships from public.process_fleet_movements();
    exception when others then v_ships := -1; end;
    v_lines := array_append(v_lines, format('4. idempotence passes -> rows=%s/%s', v_rows, v_ships));
    v_res := array_append(v_res, case when v_rows = 0 and v_ships = 0 then 'PASS' else 'FAIL' end);

    select coalesce(quantity, 0) into v_ships from public.planet_ships where planet_id = v_planet and ship_id = v_ship;
    select count(*) into v_msgs from public.player_messages where dedupe_key like 'fleet%';
    v_lines := array_append(v_lines, format('5. final: ships at origin=%s messages=%s fleet rows=%s',
        v_ships, v_msgs, (select count(*) from public.fleet_movement_ships where fleet_id = v_f)));
    v_res := array_append(v_res, case when v_ships = 6 and v_msgs <= 4 then 'PASS' else 'FAIL' end);

    for v_rows in 1..array_length(v_res, 1) loop
        insert into t_fwc values (v_res[v_rows], v_lines[v_rows]);
    end loop;
end;
$d$;
select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) as assertions, count(*) filter (where resultado = 'PASS') as passed from t_fwc;
select resultado, prueba from t_fwc order by prueba;
drop table if exists t_fwc;
rollback;