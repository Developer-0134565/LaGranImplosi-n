CREATE OR REPLACE FUNCTION public.project_planet_resources(p_planet_id uuid, p_minutes numeric)
RETURNS TABLE(
    planet_id uuid,
    minutes_forward numeric,
    projected_metal numeric,
    projected_crystal numeric,
    projected_deuterium numeric,
    projected_energy numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_universe_id uuid;
    v_now timestamptz := now();
    v_until timestamptz;
    v_metal_hour numeric;
    v_crystal_hour numeric;
    v_deuterium_hour numeric;
    v_economy_rate numeric;
    v_production_rate numeric;
    v_combined_rate numeric;
    v_weighted_evolution_seconds numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
    v_energy_balance numeric;
BEGIN
    IF p_minutes < 0 THEN
        RAISE EXCEPTION 'p_minutes debe ser >= 0';
    END IF;

    SELECT
        pr.metal,
        pr.crystal,
        pr.deuterium,
        pr.energy
    INTO
        v_metal,
        v_crystal,
        v_deuterium,
        v_energy
    FROM public.planet_resources pr
    WHERE pr.planet_id = p_planet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existen recursos para el planeta %', p_planet_id;
    END IF;

    SELECT p.universe_id
    INTO v_universe_id
    FROM public.planets p
    WHERE p.id = p_planet_id;

    IF v_universe_id IS NULL THEN
        RAISE EXCEPTION 'Planeta % no encontrado', p_planet_id;
    END IF;

    v_until := v_now + make_interval(secs => p_minutes * 60.0);

    SELECT
        pp.metal_per_hour,
        pp.crystal_per_hour,
        pp.deuterium_per_hour
    INTO
        v_metal_hour,
        v_crystal_hour,
        v_deuterium_hour
    FROM public.calculate_planet_production(p_planet_id) pp;

    SELECT r.economy, r.production
    INTO v_economy_rate, v_production_rate
    FROM public.calculate_universe_rates(v_universe_id) r;

    v_combined_rate := v_economy_rate * v_production_rate;
    v_weighted_evolution_seconds := public.calculate_universe_evolution_production_seconds(
        v_universe_id,
        v_now,
        v_until
    );

    IF v_combined_rate > 0 THEN
        v_metal_produced := (v_metal_hour / v_combined_rate)
            * v_weighted_evolution_seconds / 3600.0;
        v_crystal_produced := (v_crystal_hour / v_combined_rate)
            * v_weighted_evolution_seconds / 3600.0;
        v_deuterium_produced := (v_deuterium_hour / v_combined_rate)
            * v_weighted_evolution_seconds / 3600.0;
    ELSE
        v_metal_produced := 0;
        v_crystal_produced := 0;
        v_deuterium_produced := 0;
    END IF;

    SELECT
        s.metal_capacity,
        s.crystal_capacity,
        s.deuterium_capacity
    INTO
        v_metal_capacity,
        v_crystal_capacity,
        v_deuterium_capacity
    FROM public.calculate_planet_storage(p_planet_id) s;

    SELECT energy_balance_per_hour
    INTO v_energy_balance
    FROM public.calculate_planet_energy_balance(p_planet_id);

    RETURN QUERY
    SELECT
        p_planet_id,
        p_minutes,
        ROUND(LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced)), 6),
        ROUND(LEAST(v_crystal_capacity, GREATEST(0, v_crystal + v_crystal_produced)), 6),
        ROUND(LEAST(v_deuterium_capacity, GREATEST(0, v_deuterium + v_deuterium_produced)), 6),
        ROUND(v_energy + v_energy_balance * p_minutes / 60.0, 6);
END;
$$;

CREATE OR REPLACE FUNCTION public.simulate_building_step_snapshot(
    p_planet_id uuid,
    p_building_id text,
    p_virtual_level integer,
    p_metal numeric,
    p_crystal numeric,
    p_deuterium numeric,
    p_metal_per_hour numeric,
    p_crystal_per_hour numeric,
    p_deuterium_per_hour numeric,
    p_energy_per_hour numeric,
    p_economy_rate numeric,
    p_production_rate numeric,
    p_building_rate numeric
)
RETURNS TABLE(
    building_id text,
    current_level integer,
    target_level integer,
    duration_seconds numeric,
    starting_metal numeric,
    starting_crystal numeric,
    starting_deuterium numeric,
    cost_metal numeric,
    cost_crystal numeric,
    cost_deuterium numeric,
    affordable boolean,
    resulting_metal numeric,
    resulting_crystal numeric,
    resulting_deuterium numeric,
    resulting_metal_per_hour numeric,
    resulting_crystal_per_hour numeric,
    resulting_deuterium_per_hour numeric,
    resulting_energy_per_hour numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_target_level integer;
    v_duration numeric;
    v_cost_metal numeric;
    v_cost_crystal numeric;
    v_cost_deuterium numeric;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_metal_level integer := 0;
    v_crystal_level integer := 0;
    v_deuterium_level integer := 0;
    v_solar_level integer := 0;
    v_energy_production numeric;
    v_energy_consumption numeric;
    v_production_factor numeric := 1;
BEGIN
    IF p_virtual_level < 0 THEN
        RAISE EXCEPTION 'El nivel virtual debe ser >= 0';
    END IF;

    IF p_economy_rate <= 0 OR p_production_rate <= 0 OR p_building_rate <= 0 THEN
        RAISE EXCEPTION 'Las tasas del snapshot deben ser mayores que 0';
    END IF;

    v_target_level := p_virtual_level + 1;

    SELECT c.metal, c.crystal, c.deuterium
    INTO v_cost_metal, v_cost_crystal, v_cost_deuterium
    FROM public.calculate_building_cost(p_building_id, v_target_level) c;

    SELECT
        bd.base_build_time_seconds
        * power(bd.time_factor, v_target_level - 1)
        / p_building_rate
    INTO v_duration
    FROM public.building_definitions bd
    WHERE bd.id = p_building_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Edificio no encontrado: %', p_building_id;
    END IF;

    building_id := p_building_id;
    current_level := p_virtual_level;
    target_level := v_target_level;
    duration_seconds := v_duration;
    starting_metal := p_metal;
    starting_crystal := p_crystal;
    starting_deuterium := p_deuterium;
    cost_metal := v_cost_metal;
    cost_crystal := v_cost_crystal;
    cost_deuterium := v_cost_deuterium;
    affordable := p_metal >= v_cost_metal
        AND p_crystal >= v_cost_crystal
        AND p_deuterium >= v_cost_deuterium;

    IF NOT affordable THEN
        resulting_metal := p_metal;
        resulting_crystal := p_crystal;
        resulting_deuterium := p_deuterium;
        resulting_metal_per_hour := p_metal_per_hour;
        resulting_crystal_per_hour := p_crystal_per_hour;
        resulting_deuterium_per_hour := p_deuterium_per_hour;
        resulting_energy_per_hour := p_energy_per_hour;
        RETURN NEXT;
        RETURN;
    END IF;

    v_metal := p_metal - v_cost_metal
        + p_metal_per_hour * v_duration / 3600.0;
    v_crystal := p_crystal - v_cost_crystal
        + p_crystal_per_hour * v_duration / 3600.0;
    v_deuterium := p_deuterium - v_cost_deuterium
        + p_deuterium_per_hour * v_duration / 3600.0;

    SELECT
        COALESCE(MAX(pb.level) FILTER (WHERE pb.building_id = 'metal_mine'), 0),
        COALESCE(MAX(pb.level) FILTER (WHERE pb.building_id = 'crystal_mine'), 0),
        COALESCE(MAX(pb.level) FILTER (WHERE pb.building_id = 'deuterium_synthesizer'), 0),
        COALESCE(MAX(pb.level) FILTER (WHERE pb.building_id = 'solar_plant'), 0)
    INTO
        v_metal_level,
        v_crystal_level,
        v_deuterium_level,
        v_solar_level
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id;

    IF p_building_id = 'metal_mine' THEN
        v_metal_level := v_target_level;
    ELSIF p_building_id = 'crystal_mine' THEN
        v_crystal_level := v_target_level;
    ELSIF p_building_id = 'deuterium_synthesizer' THEN
        v_deuterium_level := v_target_level;
    ELSIF p_building_id = 'solar_plant' THEN
        v_solar_level := v_target_level;
    END IF;

    v_energy_production := floor(
        20 * v_solar_level * power(1.1, v_solar_level)
    );

    SELECT COALESCE(SUM(
        public.calculate_building_energy_consumption(
            pb.building_id,
            pb.level
        )
    ), 0)
    INTO v_energy_consumption
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id
      AND pb.building_id <> p_building_id;

    v_energy_consumption := v_energy_consumption
        + public.calculate_building_energy_consumption(p_building_id, v_target_level);

    IF v_energy_consumption > 0 THEN
        v_production_factor := GREATEST(
            0,
            LEAST(1, v_energy_production / v_energy_consumption)
        );
    END IF;

    resulting_metal_per_hour :=
        30 * v_metal_level * power(1.1, v_metal_level)
        * p_economy_rate * p_production_rate
        * v_production_factor;

    resulting_crystal_per_hour :=
        20 * v_crystal_level * power(1.1, v_crystal_level)
        * p_economy_rate * p_production_rate
        * v_production_factor;

    resulting_deuterium_per_hour :=
        10 * v_deuterium_level * power(1.1, v_deuterium_level)
        * p_economy_rate * p_production_rate
        * v_production_factor;

    resulting_energy_per_hour := v_energy_production;

    resulting_metal := v_metal;
    resulting_crystal := v_crystal;
    resulting_deuterium := v_deuterium;

    RETURN NEXT;
END;
$$;