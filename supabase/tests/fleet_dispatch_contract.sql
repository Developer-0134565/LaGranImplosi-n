-- LGI - fleet dispatch contract fixture (migration 20260926250000)
-- Transactional: BEGIN ... ROLLBACK, zero residue. Proves that the single-ship dispatch contract works for
-- every mission the frontend exposes and that all its business refusals are still intact.
begin;
drop table if exists t_fd;
create temp table t_fd(resultado text, prueba text);
do $d$
declare
    v_user uuid; v_player uuid; v_planet uuid; v_dest uuid; v_ship text := 'light_fighter';
    v_err text; v_lines text[] := array[]::text[]; v_res text[] := array[]::text[];
    v_fleet uuid; v_qty bigint; v_fuel numeric;
begin
    select pl.id, pl.user_id into v_player, v_user from public.players pl
     where pl.user_id is not null order by pl.created_at limit 1;
    select p.id into v_planet from public.planets p where p.player_id = v_player and not p.is_destroyed
     order by p.is_homeworld desc limit 1;
    select p.id into v_dest from public.planets p where p.id <> v_planet and not p.is_destroyed
       and p.kind = 'PLANET' order by p.created_at limit 1;

    /* deterministic fleet + fuel for the fixture */
    insert into public.planet_ships (planet_id, ship_id, quantity) values (v_planet, v_ship, 20)
    on conflict (planet_id, ship_id) do update set quantity = 20;
    update public.planet_resources set deuterium = greatest(deuterium, 1000000) where planet_id = v_planet;
    delete from public.fleet_movements where origin_planet_id = v_planet;

    /* the player must own enough fleet slots for three dispatches: slots derive from computer technology */
    insert into public.player_research (player_id, research_id, level) values (v_player, 'computer_technology', 5)
    on conflict (player_id, research_id) do update set level = 5;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

    /* 1. TRANSPORT (GalaxyView + App path) - must create the fleet */
    v_err := null; v_fleet := null;
    begin
        select f.fleet_id into v_fleet from public.start_fleet(v_player, v_planet, v_dest, v_ship, 3, 'TRANSPORT') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err is null and v_fleet is not null then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('1. start_fleet TRANSPORT -> %s', coalesce(v_err, 'fleet ' || v_fleet::text)));

    /* 2. EXPEDITION with a NULL destination (GalaxyView expedition button) */
    v_err := null;
    begin
        select f.fleet_id into v_fleet from public.start_fleet(v_player, v_planet, null, v_ship, 2, 'EXPEDITION') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err is null then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('2. start_fleet EXPEDITION (dest=NULL) -> %s', coalesce(v_err, 'OK')));

    /* 3. ship consumption + fuel bookkeeping really happened */
    select quantity into v_qty from public.planet_ships where planet_id = v_planet and ship_id = v_ship;
    select coalesce(sum(fuel_consumed), 0) into v_fuel from public.fleet_movements where origin_planet_id = v_planet;
    v_res := array_append(v_res, case when v_qty = 15 and v_fuel > 0 then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('3. ships consumed 20-3-2 -> %s ; fuel charged %s', v_qty, v_fuel));

    /* 4. the ambiguity regression guard: the function text is qualified */
    v_res := array_append(v_res, case when (select position('AS ps SET quantity' in prosrc) > 0 from pg_proc
        where pronamespace='public'::regnamespace and proname='start_fleet') then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, '4. regression guard: ship UPDATE qualified with the planet_ships alias');

    /* 5. business refusals still intact */
    v_err := null;
    begin perform f.* from public.start_fleet(v_player, v_planet, v_dest, v_ship, 999999, 'TRANSPORT') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err like 'Not enough%' then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('5a. over-quantity refused -> %s', coalesce(v_err, '(no error!)')));

    v_err := null;
    begin perform f.* from public.start_fleet(v_player, v_planet, v_dest, v_ship, 1, 'BOGUS') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err like 'Invalid mission type%' then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('5b. invalid mission refused -> %s', coalesce(v_err, '(no error!)')));

    v_err := null;
    begin perform f.* from public.start_fleet(v_player, v_planet, v_dest, 'no_such_ship', 1, 'TRANSPORT') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err is not null and v_err not like '%ambiguous%' then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('5c. unknown ship refused (business) -> %s', coalesce(v_err, '(no error!)')));

    /* 6. a foreign actor still cannot dispatch with somebody else''s player id */
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    v_err := null;
    begin perform f.* from public.start_fleet(v_player, v_planet, v_dest, v_ship, 1, 'TRANSPORT') f;
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    v_res := array_append(v_res, case when v_err like 'Player does not belong%' then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('6. foreign actor refused -> %s', coalesce(v_err, '(no error!)')));

    /* 7. the mixed path keeps working (App.tsx control) */
    v_err := null;
    begin select f.fleet_id into v_fleet from public.start_fleet_mixed(v_player, v_planet, v_dest,
              jsonb_build_object(v_ship, 1), 'TRANSPORT') f;
    exception when others then v_err := sqlerrm; end;
    v_res := array_append(v_res, case when v_err is null then 'PASS' else 'FAIL' end);
    v_lines := array_append(v_lines, format('7. start_fleet_mixed (control) -> %s', coalesce(v_err, 'OK')));

    perform set_config('role', 'postgres', true);
    for v_qty in 1..array_length(v_res, 1) loop
        insert into t_fd values (v_res[v_qty], v_lines[v_qty]);
    end loop;
end;
$d$;
select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) as assertions, count(*) filter (where resultado = 'PASS') as passed from t_fd;
select resultado, prueba from t_fd order by prueba;
drop table if exists t_fd;
rollback;