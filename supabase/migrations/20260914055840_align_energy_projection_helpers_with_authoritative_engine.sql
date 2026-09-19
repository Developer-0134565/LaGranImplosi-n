create or replace function public.project_building_production(p_planet_id uuid, p_building_id text)
returns table(planet_id uuid, building_id text, current_level integer, target_level integer, current_metal_per_hour numeric, target_metal_per_hour numeric, metal_delta_per_hour numeric, current_crystal_per_hour numeric, target_crystal_per_hour numeric, crystal_delta_per_hour numeric, current_deuterium_per_hour numeric, target_deuterium_per_hour numeric, deuterium_delta_per_hour numeric, current_energy_per_hour numeric, target_energy_per_hour numeric, energy_delta_per_hour numeric)
language plpgsql stable set search_path to 'public','pg_temp'
as $function$
declare
 v_current_level integer:=0; v_target_level integer;
 v_current_metal numeric:=0; v_current_crystal numeric:=0; v_current_deuterium numeric:=0; v_current_energy numeric:=0;
 v_target_metal numeric:=0; v_target_crystal numeric:=0; v_target_deuterium numeric:=0; v_target_energy numeric:=0;
begin
 select coalesce(pb.level,0) into v_current_level from public.planet_buildings pb where pb.planet_id=p_planet_id and pb.building_id=p_building_id;
 v_current_level:=coalesce(v_current_level,0); v_target_level:=v_current_level+1;
 select pp.metal_per_hour,pp.crystal_per_hour,pp.deuterium_per_hour,pp.energy_per_hour into v_current_metal,v_current_crystal,v_current_deuterium,v_current_energy from public.calculate_planet_production(p_planet_id) pp;
 v_target_metal:=v_current_metal; v_target_crystal:=v_current_crystal; v_target_deuterium:=v_current_deuterium; v_target_energy:=v_current_energy;
 if p_building_id='metal_mine' then
   select 30*v_target_level*power(1.1,v_target_level)*ur.economy*ur.production into v_target_metal from public.planets p cross join lateral public.calculate_universe_rates(p.universe_id) ur where p.id=p_planet_id;
 elsif p_building_id='crystal_mine' then
   select 20*v_target_level*power(1.1,v_target_level)*ur.economy*ur.production into v_target_crystal from public.planets p cross join lateral public.calculate_universe_rates(p.universe_id) ur where p.id=p_planet_id;
 elsif p_building_id='deuterium_synthesizer' then
   select 10*v_target_level*power(1.1,v_target_level)*ur.economy*ur.production into v_target_deuterium from public.planets p cross join lateral public.calculate_universe_rates(p.universe_id) ur where p.id=p_planet_id;
 elsif p_building_id='solar_plant' then
   v_target_energy:=floor(20*v_target_level*power(1.1,v_target_level));
 else
   raise exception 'Building % does not directly produce resources',p_building_id;
 end if;
 return query select p_planet_id,p_building_id,v_current_level,v_target_level,
   v_current_metal,v_target_metal,v_target_metal-v_current_metal,
   v_current_crystal,v_target_crystal,v_target_crystal-v_current_crystal,
   v_current_deuterium,v_target_deuterium,v_target_deuterium-v_current_deuterium,
   v_current_energy,v_target_energy,v_target_energy-v_current_energy;
end;
$function$;

create or replace function public.simulate_building_completion(p_planet_id uuid, p_building_id text)
returns table(planet_id uuid, building_id text, current_level integer, target_level integer, duration_seconds numeric, starting_metal numeric, starting_crystal numeric, starting_deuterium numeric, resources_at_completion_metal numeric, resources_at_completion_crystal numeric, resources_at_completion_deuterium numeric, cost_metal numeric, cost_crystal numeric, cost_deuterium numeric, resulting_metal numeric, resulting_crystal numeric, resulting_deuterium numeric, current_metal_per_hour numeric, resulting_metal_per_hour numeric, current_crystal_per_hour numeric, resulting_crystal_per_hour numeric, current_deuterium_per_hour numeric, resulting_deuterium_per_hour numeric, current_energy_per_hour numeric, resulting_energy_per_hour numeric)
language plpgsql stable set search_path to 'public','pg_temp'
as $function$
declare
 v_current_level integer:=0; v_target_level integer; v_duration numeric; v_start_metal numeric; v_start_crystal numeric; v_start_deuterium numeric; v_metal_hour numeric; v_crystal_hour numeric; v_deuterium_hour numeric; v_energy_hour numeric; v_completion_metal numeric; v_completion_crystal numeric; v_completion_deuterium numeric; v_cost_metal numeric; v_cost_crystal numeric; v_cost_deuterium numeric; v_result_metal numeric; v_result_crystal numeric; v_result_deuterium numeric; v_result_metal_hour numeric; v_result_crystal_hour numeric; v_result_deuterium_hour numeric; v_result_energy_hour numeric; v_economy_rate numeric; v_production_rate numeric; v_universe_id uuid;
begin
 select p.universe_id into v_universe_id from public.planets p where p.id=p_planet_id; if not found then raise exception 'Planeta % no encontrado',p_planet_id; end if;
 select coalesce(pb.level,0) into v_current_level from public.planet_buildings pb where pb.planet_id=p_planet_id and pb.building_id=p_building_id; v_current_level:=coalesce(v_current_level,0); v_target_level:=v_current_level+1;
 select pr.metal,pr.crystal,pr.deuterium into v_start_metal,v_start_crystal,v_start_deuterium from public.planet_resources pr where pr.planet_id=p_planet_id; if not found then raise exception 'No existen recursos para el planeta %',p_planet_id; end if;
 select pp.metal_per_hour,pp.crystal_per_hour,pp.deuterium_per_hour,pp.energy_per_hour into v_metal_hour,v_crystal_hour,v_deuterium_hour,v_energy_hour from public.calculate_planet_production(p_planet_id) pp;
 select r.economy_rate,r.production_rate into v_economy_rate,v_production_rate from public.get_planet_economic_rates(p_planet_id) r;
 v_duration:=public.calculate_building_time(p_building_id,v_target_level,v_universe_id);
 select c.metal,c.crystal,c.deuterium into v_cost_metal,v_cost_crystal,v_cost_deuterium from public.calculate_building_cost(p_building_id,v_target_level) c;
 v_completion_metal:=v_start_metal+v_metal_hour*v_duration/3600; v_completion_crystal:=v_start_crystal+v_crystal_hour*v_duration/3600; v_completion_deuterium:=v_start_deuterium+v_deuterium_hour*v_duration/3600;
 v_result_metal:=v_completion_metal-v_cost_metal; v_result_crystal:=v_completion_crystal-v_cost_crystal; v_result_deuterium:=v_completion_deuterium-v_cost_deuterium;
 v_result_metal_hour:=v_metal_hour; v_result_crystal_hour:=v_crystal_hour; v_result_deuterium_hour:=v_deuterium_hour; v_result_energy_hour:=v_energy_hour;
 if p_building_id='metal_mine' then v_result_metal_hour:=30*v_target_level*power(1.1,v_target_level)*v_economy_rate*v_production_rate;
 elsif p_building_id='crystal_mine' then v_result_crystal_hour:=20*v_target_level*power(1.1,v_target_level)*v_economy_rate*v_production_rate;
 elsif p_building_id='deuterium_synthesizer' then v_result_deuterium_hour:=10*v_target_level*power(1.1,v_target_level)*v_economy_rate*v_production_rate;
 elsif p_building_id='solar_plant' then v_result_energy_hour:=floor(20*v_target_level*power(1.1,v_target_level)); end if;
 return query select p_planet_id,p_building_id,v_current_level,v_target_level,v_duration,v_start_metal,v_start_crystal,v_start_deuterium,v_completion_metal,v_completion_crystal,v_completion_deuterium,v_cost_metal,v_cost_crystal,v_cost_deuterium,v_result_metal,v_result_crystal,v_result_deuterium,v_metal_hour,v_result_metal_hour,v_crystal_hour,v_result_crystal_hour,v_deuterium_hour,v_result_deuterium_hour,v_energy_hour,v_result_energy_hour;
end;
$function$;