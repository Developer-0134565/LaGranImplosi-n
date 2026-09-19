create or replace function public.process_building_queue_for_planet(p_planet_id uuid)
returns table(queue_id uuid, planet_id uuid, building_id text, completed_level integer)
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_queue record;
    v_completed_level integer;
begin
    for v_queue in
        select bq.id, bq.planet_id, bq.building_id
        from public.building_queue as bq
        where bq.planet_id = p_planet_id
          and bq.status = 'BUILDING'
          and bq.finishes_at <= now()
        order by bq.created_at asc
        for update skip locked
    loop
        v_completed_level := public.complete_building(v_queue.id);
        queue_id := v_queue.id;
        planet_id := v_queue.planet_id;
        building_id := v_queue.building_id;
        completed_level := v_completed_level;
        return next;
    end loop;
end;
$function$;

grant execute on function public.process_building_queue_for_planet(uuid) to public;

create or replace function public.process_planet_tick(p_planet_id uuid)
returns table(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, buildings_completed integer, researches_completed integer)
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_result record;
    v_buildings_completed integer := 0;
    v_researches_completed integer := 0;
begin
    select * into v_result
    from public.process_planet_tick_local(p_planet_id);

    select count(*)
    into v_buildings_completed
    from public.process_building_queue_for_planet(p_planet_id) b;

    select count(*)
    into v_researches_completed
    from public.process_research_queue() r
    where r.player_id = (
        select p.player_id
        from public.planets p
        where p.id = p_planet_id
    );

    return query
    select
        v_result.planet_id,
        v_result.metal,
        v_result.crystal,
        v_result.deuterium,
        v_result.energy,
        v_buildings_completed,
        v_researches_completed;
end;
$function$;