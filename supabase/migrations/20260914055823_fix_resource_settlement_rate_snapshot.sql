create or replace function public.update_planet_resources_until(p_planet_id uuid, p_until timestamp with time zone)
returns table(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, metal_produced numeric, crystal_produced numeric, deuterium_produced numeric)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_last_calculated_at timestamptz;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_elapsed_seconds numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_weighted_evolution_seconds numeric;
    v_economy_rate numeric;
    v_production_rate numeric;
    v_current_combined_rate numeric;
    v_metal_base_per_hour numeric;
    v_crystal_base_per_hour numeric;
    v_deuterium_base_per_hour numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
    v_universe_id uuid;
begin
    select pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy
      into v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    from public.planet_resources pr
    where pr.planet_id = p_planet_id
    for update;

    if not found then raise exception 'PLANET_RESOURCES_NOT_FOUND'; end if;
    if p_until < v_last_calculated_at then raise exception 'INVALID_RESOURCE_TIMESTAMP'; end if;

    select p.universe_id into v_universe_id
    from public.planets p where p.id = p_planet_id;
    if v_universe_id is null then raise exception 'PLANET_NOT_FOUND'; end if;

    v_elapsed_seconds := greatest(0, extract(epoch from (p_until - v_last_calculated_at)));

    select pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour
      into v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour
    from public.calculate_planet_production(p_planet_id) pp;

    select r.economy, r.production
      into v_economy_rate, v_production_rate
    from public.calculate_universe_rates(v_universe_id) r;

    v_current_combined_rate := v_economy_rate * v_production_rate;
    v_weighted_evolution_seconds := public.calculate_universe_evolution_production_seconds(v_universe_id, v_last_calculated_at, p_until);

    if v_current_combined_rate > 0 then
        v_metal_base_per_hour := v_metal_per_hour / v_current_combined_rate;
        v_crystal_base_per_hour := v_crystal_per_hour / v_current_combined_rate;
        v_deuterium_base_per_hour := v_deuterium_per_hour / v_current_combined_rate;
        v_metal_produced := v_metal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_crystal_produced := v_crystal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_deuterium_produced := v_deuterium_base_per_hour * v_weighted_evolution_seconds / 3600.0;
    else
        v_metal_produced := 0; v_crystal_produced := 0; v_deuterium_produced := 0;
    end if;

    select s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
      into v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    from public.calculate_planet_storage(p_planet_id) s;

    v_metal := least(v_metal_capacity, greatest(0, v_metal + v_metal_produced));
    v_crystal := least(v_crystal_capacity, greatest(0, v_crystal + v_crystal_produced));
    v_deuterium := least(v_deuterium_capacity, greatest(0, v_deuterium + v_deuterium_produced));

    update public.planet_resources pr
       set metal = v_metal, crystal = v_crystal, deuterium = v_deuterium,
           last_calculated_at = p_until, updated_at = now()
     where pr.planet_id = p_planet_id;

    planet_id := p_planet_id; metal := v_metal; crystal := v_crystal; deuterium := v_deuterium; energy := v_energy;
    elapsed_seconds := v_elapsed_seconds; metal_produced := v_metal_produced; crystal_produced := v_crystal_produced; deuterium_produced := v_deuterium_produced;
    return next;
end;
$function$;