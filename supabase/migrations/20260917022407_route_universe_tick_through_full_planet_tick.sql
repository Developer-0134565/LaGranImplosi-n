create or replace function public.process_universe_tick(p_universe_id uuid)
 returns table(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, buildings_completed integer, researches_completed integer)
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_planet record;
  v_result record;
begin
  -- Drain fleet events first. This is deliberately before ANY planet resource
  -- settlement so late arrivals/returns remain ordered by their logical event
  -- timestamp even when the heartbeat is catching up after downtime.
  perform public.process_fleet_movements();

  for v_planet in
    select p.id
    from public.planets p
    where p.universe_id=p_universe_id
      and not p.is_destroyed
    order by p.created_at,p.id
  loop
    select * into v_result from public.process_planet_tick(v_planet.id);
    return query
    select v_result.planet_id,v_result.metal,v_result.crystal,v_result.deuterium,
           v_result.energy,v_result.buildings_completed,v_result.researches_completed;
  end loop;
end;
$function$;