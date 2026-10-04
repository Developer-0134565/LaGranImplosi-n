-- CRAWLER OVERLOAD + DEMOLITION/ION + QUEUE EXPIRY — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Mission 2026-10-03. Three behaviours, three different provenances:
--   * QUEUE EXPIRY    already conformant in LGI -> certified, NOT rewritten.
--   * DEMOLITION/ION  already conformant in LGI -> certified, NOT rewritten.
--   * CRAWLER OVERLOAD was the real gap        -> implemented by 20261004000000.
--
-- LIMITATION: single-session harness; true concurrency not executed.

begin;

drop table if exists t_mis;
create temp table t_mis(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_rival uuid;
    v_origin uuid; v_target_p uuid; v_far uuid;
    v_res record; v_ok boolean;
    v_energy numeric; v_prod numeric; v_prod100 numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    if v_player is null then raise exception 'TEST_ABORT: se requiere un jugador con auth'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    select pl.id into v_rival from public.players pl
     where pl.id <> v_player and pl.universe_id = v_universe order by pl.created_at, pl.id limit 1;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, kind, is_homeworld, is_destroyed)
    values (v_universe, v_player,'CO-ORIGIN',1,200,1,'PLANET',false,false),
           (v_universe, v_rival,'CO-TARGET',1,201,4,'PLANET',false,false);
    select id into v_origin from public.planets where name='CO-ORIGIN' and player_id=v_player;
    select id into v_target_p from public.planets where name='CO-TARGET';

    insert into public.planet_resources(planet_id,metal,crystal,deuterium)
    values (v_origin,50000000,50000000,50000000);
    insert into public.planet_buildings(planet_id,building_id,level)
    values (v_origin,'metal_mine',10),(v_origin,'crystal_mine',10),(v_origin,'deuterium_synthesizer',10),
           (v_origin,'solar_plant',10)
      on conflict (planet_id,building_id) do update set level=excluded.level;
    insert into public.planet_ships(planet_id,ship_id,quantity) values (v_origin,'crawler',10)
      on conflict (planet_id,ship_id) do update set quantity=10;

    -- ==================================================================
    -- A. CRAWLER OVERLOAD — formula pura (OGameX)
    -- ==================================================================
    v_ok := public.calculate_crawler_overload_energy(1,100)=50;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A1. 100 % => 50 de energia por crawler');
    v_ok := public.calculate_crawler_overload_energy(1,110)=60
         and public.calculate_crawler_overload_energy(1,120)=70
         and public.calculate_crawler_overload_energy(1,130)=80
         and public.calculate_crawler_overload_energy(1,140)=90
         and public.calculate_crawler_overload_energy(1,150)=100;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A2. 110/120/130/140/150 % => 60/70/80/90/100 (OGameX exacto)');
    v_ok := public.calculate_crawler_overload_energy(0,150)=0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A3. sin crawlers => 0 energia, sea cual sea el overload');
    v_ok := public.calculate_crawler_overload_energy(10,150) > public.calculate_crawler_overload_energy(10,100)*1.5;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A4. el overload penaliza: a 150 % la energia supera 1.5x la del 100 % (p + (p-1))');
    v_ok := public.calculate_crawler_effective_count(v_origin)=10;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A5. tope efectivo = min(10 crawlers, (10+10+10)*8=240) = 10');

-- ==================================================================
    -- B. CRAWLER OVERLOAD — extremo a extremo, autorizado y validado
    -- ==================================================================
    update public.planets set crawler_percentage = 100 where id = v_origin;
    select * into v_res from public.set_planet_crawler_percentage(v_player, v_origin, 100);
    v_energy := v_res.crawler_energy_per_hour;
    v_ok := v_res.crawler_percentage=100 and v_res.crawler_production_multiplier=1 and v_energy=500;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B1. 100 %% e2e: multiplicador 1 y energia %s (10 crawlers x 50)', v_energy));

    select * into v_res from public.set_planet_crawler_percentage(v_player, v_origin, 150);
    v_energy := v_res.crawler_energy_per_hour;
    v_ok := v_res.crawler_percentage=150 and v_res.crawler_production_multiplier=1.5 and v_energy=1000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B2. 150 %% e2e: multiplicador 1.5 y energia %s (10 crawlers x 100)', v_energy));

    v_ok := public.calculate_crawler_energy_consumption(v_origin)=1000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'B3. calculate_crawler_energy_consumption = 1000 a 150 % (motor real)');

    -- B4. La produccion sigue al porcentaje. Para Aislar el efecto del overload hay
    --     que dar HOLGURA ENERGETICA: si el consumo de energia es el factor limitante,
    --     subir el overload sube el consumo, el factor energetico baja y la produccion
    --     total puede BAJAR. Eso no es un defecto: es el guard de sostenibilidad
    --     existente actuandose (certificado aparte en F1).
    update public.planet_buildings set level = 30
      where planet_id = v_origin and building_id = 'solar_plant';
    update public.planets set crawler_percentage = 150 where id = v_origin;
    select pp.metal_per_hour into v_prod from public.calculate_planet_production(v_origin) pp;
    update public.planets set crawler_percentage = 100 where id = v_origin;
    select pp.metal_per_hour into v_prod100 from public.calculate_planet_production(v_origin) pp;
    v_ok := v_prod > v_prod100;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('B4. con holgura energetica, produccion metal/h 150%% > 100%%', v_prod > v_prod100));
    update public.planets set crawler_percentage = 150 where id = v_origin;

    begin
        perform public.set_planet_crawler_percentage(v_player, v_origin, 151);
        v_ok := false;
    exception when others then v_ok := sqlerrm like '%OUT_OF_RANGE%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'B5. 151 % rechazado server-side');
    begin
        perform public.set_planet_crawler_percentage(v_player, v_origin, -1);
        v_ok := false;
    exception when others then v_ok := sqlerrm like '%OUT_OF_RANGE%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'B6. -1 % rechazado server-side');
    v_ok := (select crawler_percentage from public.planets where id=v_origin)=150;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'B7. los rechazos NO tocan el valor persistido (sigue 150)');

    -- ==================================================================
    -- C. SEGURIDAD / OWNERSHIP
    -- ==================================================================
    begin
        perform public.set_planet_crawler_percentage(v_player, v_target_p, 150);
        v_ok := false;
    exception when others then v_ok := sqlerrm like '%PLANET_NOT_FOUND_OR_NOT_OWNED%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C1. un jugador NO puede tocar el crawler de un cuerpo ajeno (rechazo en servidor)');
    begin
        perform public.set_planet_crawler_percentage(v_rival, v_origin, 150);
        v_ok := false;
    exception when others then v_ok := sqlerrm like '%PLAYER_NOT_OWNED_BY_AUTH_USER%';
    end;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C2. un player_id falsificado es rechazado (manda auth.uid())');
    v_ok := (select crawler_percentage from public.planets where id=v_target_p)=100;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C3. el cuerpo ajeno conserva 100 % tras los intentos');
    v_ok := has_function_privilege('anon','public.set_planet_crawler_percentage(uuid,uuid,integer)','EXECUTE')=false
       and has_function_privilege('authenticated','public.set_planet_crawler_percentage(uuid,uuid,integer)','EXECUTE')
       and has_function_privilege('anon','public.get_planet_crawler_status(uuid)','EXECUTE')=false;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C4. ACL: authenticated ejecuta la accion; anon no');
    v_ok := has_function_privilege('authenticated','public.calculate_crawler_overload_energy(bigint,integer)','EXECUTE')=false
-- ==================================================================
    -- D. DEMOLITION + ION (ya implementado: se certifica, no se reescribe)
    -- ==================================================================
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,0)).metal
            = floor((public.calculate_building_cost('metal_mine',10)).metal);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D1. Ion 0 => coste de construccion del nivel, con floor por recurso (calculate_building_cost es fraccionario)');
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,1)).metal
            = floor((public.calculate_building_cost('metal_mine',10)).metal * 0.96);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D2. Ion 1 => 96 % (4 % por nivel)');
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,5)).metal
            = floor((public.calculate_building_cost('metal_mine',10)).metal * 0.80);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D3. Ion 5 => 80 % del coste base');
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,10)).metal
            = floor((public.calculate_building_cost('metal_mine',10)).metal * 0.60);
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D4. Ion 10 => 60 % del coste base, con floor');
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,25)).metal = 0
        and (public.calculate_building_demolition_cost('metal_mine',10,25)).crystal = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D5. Ion 25 => coste 0 (reduccion del 100 %)');
    select bool_and(q.m >= 0 and q.c >= 0 and q.d >= 0) into v_ok
      from (select (public.calculate_building_demolition_cost('metal_mine',10,i)).metal m,
                   (public.calculate_building_demolition_cost('metal_mine',10,i)).crystal c,
                   (public.calculate_building_demolition_cost('metal_mine',10,i)).deuterium d
              from generate_series(0,60) i) q;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D6. Ion 0..60: nunca hay coste negativo (max 0)');
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,0)).metal
            <> (public.calculate_building_demolition_cost('metal_mine',11,0)).metal;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D7. el coste es el del nivel RETIRADO (10), no el del siguiente (11)');
-- ==================================================================
    -- E. QUEUE EXPIRY — las 4 colas (ya conforme: se certifica, no se reescribe)
    -- ==================================================================
    insert into public.building_queue(planet_id,building_id,target_level,started_at,finishes_at,status)
    values (v_origin,'metal_mine',11, now()-interval '2 hours', now()-interval '1 hour','BUILDING')
    returning id into v_far;
    perform public.process_building_queue_for_planet(v_origin);
    v_ok := (select status from public.building_queue where id=v_far)='COMPLETED'
        and (select level from public.planet_buildings where planet_id=v_origin and building_id='metal_mine')=11;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E1. cola de edificio vencida => COMPLETED con nivel aplicado (NO CANCELLED)');
    perform public.process_building_queue_for_planet(v_origin);
    v_ok := (select level from public.planet_buildings where planet_id=v_origin and building_id='metal_mine')=11;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E2. reprocesar la cola vencida no vuelve a aplicar el nivel (idempotente)');

    insert into public.research_queue(player_id,research_id,target_level,status,started_at,finishes_at)
    values (v_player,'energy_technology',1,'RESEARCHING', now()-interval '2 hours', now()-interval '1 hour')
    returning id into v_far;
    perform public.process_research_queue_for_player(v_player);
    v_ok := (select status from public.research_queue where id=v_far)='COMPLETED'
        and coalesce((select level from public.player_research
                       where player_id=v_player and research_id='energy_technology'),0) = 1;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E3. cola de investigacion vencida => COMPLETED con nivel aplicado');
    perform public.process_research_queue_for_player(v_player);
    v_ok := (select level from public.player_research
               where player_id=v_player and research_id='energy_technology')=1;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E4. reprocesar la investigacion vencida no duplica el nivel');

    insert into public.defense_queue(planet_id,defense_id,quantity,started_at,finishes_at,status)
    values (v_target_p,'rocket_launcher',3, now()-interval '2 hours', now()-interval '1 hour','BUILDING')
    returning id into v_far;
    perform public.process_defense_queue(v_target_p);
    v_ok := (select status from public.defense_queue where id=v_far)='COMPLETED'
        and (select coalesce(quantity,0) from public.planet_defenses
              where planet_id=v_target_p and defense_id='rocket_launcher')=3;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E5. cola de defensa vencida => COMPLETED con unidades aplicadas');

    insert into public.shipyard_queue(planet_id,ship_id,quantity,started_at,finishes_at,status)
    values (v_origin,'small_cargo',1, now()-interval '2 hours', now()-interval '1 hour','BUILDING')
    returning id into v_far;
    perform public.process_shipyard_queue(v_origin);
    v_ok := (select status from public.shipyard_queue where id=v_far)='COMPLETED';
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E6. cola de hangar vencida => COMPLETED');

    v_ok := not exists (select 1 from public.building_queue
                          where planet_id=v_origin and upper(status) in ('BUILDING','QUEUED','ACTIVE'));
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'E7. tras el barrido no queda ninguna cola de edificio vencida sin liquidar');

    -- ==================================================================
    -- F. SOSTENIBILIDAD: el overload entra por la ruta YA existente
    -- ==================================================================
    update public.planets set crawler_percentage = 150 where id = v_origin;
    select ((e.energy_consumption_per_hour - b.cons)::numeric(10,2))
      into v_prod
      from public.calculate_planet_energy_balance(v_origin) e,
           lateral (select coalesce(sum(public.calculate_building_energy_consumption(pb.building_id,pb.level)),0) cons
                      from public.planet_buildings pb where pb.planet_id=v_origin) b;
    v_ok := v_prod = 1000;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('F1. el saldo energetico resta exactamente el consumo del crawler (delta medido %s; esperado 1000 a 150 %%)', v_prod));
end;
$test$;

select count(*) filter (where resultado='PASS') as pass,
       count(*) filter (where resultado='FAIL') as fail
from t_mis;
select orden, resultado, prueba from t_mis order by orden;

rollback;
    v_ok := (public.calculate_building_demolition_cost('metal_mine',10,0)).deuterium = 0;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'D8. la demolicion no cuesta energia: el contrato cubre solo metal/cristal/deuterio');

       and has_function_privilege('authenticated','public.calculate_crawler_effective_count(uuid)','EXECUTE')=false;
    insert into t_mis(resultado,prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'C5. los helpers puros siguen cerrados al cliente');