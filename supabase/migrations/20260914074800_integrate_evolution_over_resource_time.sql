-- Integrate universe evolution over the actual elapsed resource interval.
-- Resource production uses economy_rate * production_rate, so the evolution
-- component is evolution^2 and must be integrated piecewise over the curve.

CREATE OR REPLACE FUNCTION public.calculate_universe_evolution_production_seconds(
    p_universe_id uuid,
    p_start_at timestamptz,
    p_end_at timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_created_at timestamptz;
    v_cursor timestamptz;
    v_end timestamptz;
    v_seg_end timestamptz;
    v_t0 numeric;
    v_t1 numeric;
    v_x0 numeric;
    v_x1 numeric;
    v_dt numeric;
    v_weighted_seconds numeric := 0;
    v_age0 numeric;
    v_age1 numeric;
    v_slope numeric;
    v_intercept numeric;
BEGIN
    SELECT created_at INTO v_created_at FROM public.universes WHERE id = p_universe_id;
    IF v_created_at IS NULL THEN RAISE EXCEPTION 'Universe % does not exist', p_universe_id; END IF;
    IF p_end_at <= p_start_at THEN RETURN 0; END IF;

    v_cursor := GREATEST(p_start_at, v_created_at);
    v_end := p_end_at;
    IF v_cursor >= v_end THEN RETURN 0; END IF;

    WHILE v_cursor < v_end LOOP
        v_age0 := GREATEST(0, EXTRACT(EPOCH FROM (v_cursor - v_created_at)) / 86400.0);
        IF v_age0 < 7 THEN v_age1 := 7;
        ELSIF v_age0 < 14 THEN v_age1 := 14;
        ELSIF v_age0 < 30 THEN v_age1 := 30;
        ELSIF v_age0 < 45 THEN v_age1 := 45;
        ELSIF v_age0 < 60 THEN v_age1 := 60;
        ELSIF v_age0 < 90 THEN v_age1 := 90;
        ELSE v_age1 := 1000000000;
        END IF;

        v_seg_end := LEAST(v_end, v_created_at + make_interval(secs => v_age1 * 86400.0));
        v_t0 := EXTRACT(EPOCH FROM (v_cursor - v_created_at));
        v_t1 := EXTRACT(EPOCH FROM (v_seg_end - v_created_at));

        IF v_age0 < 7 THEN
            v_slope := 4.0 / (7.0 * 86400.0); v_intercept := 1.0;
        ELSIF v_age0 < 14 THEN
            v_slope := 5.0 / (7.0 * 86400.0); v_intercept := 5.0 - v_slope * (7.0 * 86400.0);
        ELSIF v_age0 < 30 THEN
            v_slope := 15.0 / (16.0 * 86400.0); v_intercept := 10.0 - v_slope * (14.0 * 86400.0);
        ELSIF v_age0 < 45 THEN
            v_slope := 15.0 / (15.0 * 86400.0); v_intercept := 25.0 - v_slope * (30.0 * 86400.0);
        ELSIF v_age0 < 60 THEN
            v_slope := 20.0 / (15.0 * 86400.0); v_intercept := 40.0 - v_slope * (45.0 * 86400.0);
        ELSIF v_age0 < 90 THEN
            v_slope := 40.0 / (30.0 * 86400.0); v_intercept := 60.0 - v_slope * (60.0 * 86400.0);
        ELSE
            v_slope := 0; v_intercept := 100;
        END IF;

        v_x0 := v_slope * v_t0 + v_intercept;
        v_x1 := v_slope * v_t1 + v_intercept;
        v_dt := v_t1 - v_t0;
        v_weighted_seconds := v_weighted_seconds + v_dt * (v_x0*v_x0 + v_x0*v_x1 + v_x1*v_x1) / 3.0;
        v_cursor := v_seg_end;
    END LOOP;

    RETURN v_weighted_seconds;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_planet_resources(p_planet_id uuid)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, metal_produced numeric, crystal_produced numeric, deuterium_produced numeric)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_last_calculated_at timestamptz;
    v_now timestamptz := now();
    v_elapsed_seconds numeric;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_energy_per_hour numeric;
    v_economy_rate numeric;
    v_production_rate numeric;
    v_weighted_evolution_seconds numeric;
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
BEGIN
    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy INTO v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    FROM public.planet_resources AS pr WHERE pr.planet_id = p_planet_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe planet_resources para el planeta %', p_planet_id; END IF;

    SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id = p_planet_id;
    IF v_universe_id IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;

    v_elapsed_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_last_calculated_at)));

    SELECT pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour, pp.energy_per_hour INTO v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour, v_energy_per_hour
    FROM public.calculate_planet_production(p_planet_id) AS pp;

    SELECT r.economy, r.production INTO v_economy_rate, v_production_rate FROM public.calculate_universe_rates(v_universe_id) r;
    v_current_combined_rate := v_economy_rate * v_production_rate;
    v_weighted_evolution_seconds := public.calculate_universe_evolution_production_seconds(v_universe_id, v_last_calculated_at, v_now);

    IF v_current_combined_rate > 0 THEN
        v_metal_base_per_hour := v_metal_per_hour / v_current_combined_rate;
        v_crystal_base_per_hour := v_crystal_per_hour / v_current_combined_rate;
        v_deuterium_base_per_hour := v_deuterium_per_hour / v_current_combined_rate;
        v_metal_produced := v_metal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_crystal_produced := v_crystal_base_per_hour * v_weighted_evolution_seconds / 3600.0;
        v_deuterium_produced := v_deuterium_base_per_hour * v_weighted_evolution_seconds / 3600.0;
    ELSE
        v_metal_produced := 0; v_crystal_produced := 0; v_deuterium_produced := 0;
    END IF;

    SELECT s.metal_capacity, s.crystal_capacity, s.deuterium_capacity INTO v_metal_capacity, v_crystal_capacity, v_deuterium_capacity
    FROM public.calculate_planet_storage(p_planet_id) AS s;

    v_metal := LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced));
    v_crystal := LEAST(v_crystal_capacity, GREATEST(0, v_crystal + v_crystal_produced));
    v_deuterium := LEAST(v_deuterium_capacity, GREATEST(0, v_deuterium + v_deuterium_produced));

    UPDATE public.planet_resources AS pr SET metal = v_metal, crystal = v_crystal, deuterium = v_deuterium, last_calculated_at = v_now, updated_at = v_now WHERE pr.planet_id = p_planet_id;

    planet_id := p_planet_id; metal := v_metal; crystal := v_crystal; deuterium := v_deuterium; energy := v_energy;
    elapsed_seconds := v_elapsed_seconds; metal_produced := v_metal_produced; crystal_produced := v_crystal_produced; deuterium_produced := v_deuterium_produced;
    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_current_planet_resources(p_planet_id uuid)
RETURNS TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, projected_metal numeric, projected_crystal numeric, projected_deuterium numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_last_calculated_at timestamptz;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_energy numeric;
    v_elapsed_seconds numeric;
    v_metal_per_hour numeric;
    v_crystal_per_hour numeric;
    v_deuterium_per_hour numeric;
    v_metal_capacity numeric;
    v_crystal_capacity numeric;
    v_deuterium_capacity numeric;
    v_universe_id uuid;
    v_economy_rate numeric;
    v_production_rate numeric;
    v_current_combined_rate numeric;
    v_weighted_evolution_seconds numeric;
    v_metal_produced numeric;
    v_crystal_produced numeric;
    v_deuterium_produced numeric;
    v_now timestamptz := now();
BEGIN
    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy INTO v_last_calculated_at, v_metal, v_crystal, v_deuterium, v_energy
    FROM public.planet_resources AS pr WHERE pr.planet_id = p_planet_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe planet_resources para el planeta %', p_planet_id; END IF;

    SELECT p.universe_id INTO v_universe_id FROM public.planets p WHERE p.id = p_planet_id;
    v_elapsed_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_last_calculated_at)));

    SELECT pp.metal_per_hour, pp.crystal_per_hour, pp.deuterium_per_hour INTO v_metal_per_hour, v_crystal_per_hour, v_deuterium_per_hour
    FROM public.calculate_planet_production(p_planet_id) AS pp;

    SELECT r.economy, r.production INTO v_economy_rate, v_production_rate FROM public.calculate_universe_rates(v_universe_id) r;
    v_current_combined_rate := v_economy_rate * v_production_rate;
    v_weighted_evolution_seconds := public.calculate_universe_evolution_production_seconds(v_universe_id, v_last_calculated_at, v_now);

    IF v_current_combined_rate > 0 THEN
        v_metal_produced := (v_metal_per_hour / v_current_combined_rate) * v_weighted_evolution_seconds / 3600.0;
        v_crystal_produced := (v_crystal_per_hour / v_current_combined_rate) * v_weighted_evolution_seconds / 3600.0;
        v_deuterium_produced := (v_deuterium_per_hour / v_current_combined_rate) * v_weighted_evolution_seconds / 3600.0;
    ELSE
        v_metal_produced := 0; v_crystal_produced := 0; v_deuterium_produced := 0;
    END IF;

    SELECT s.metal_capacity, s.crystal_capacity, s.deuterium_capacity INTO v_metal_capacity, v_crystal_capacity, v_deuterium_capacity FROM public.calculate_planet_storage(p_planet_id) AS s;

    planet_id := p_planet_id; metal := ROUND(v_metal, 6); crystal := ROUND(v_crystal, 6); deuterium := ROUND(v_deuterium, 6); energy := ROUND(v_energy, 6); elapsed_seconds := ROUND(v_elapsed_seconds, 6);
    projected_metal := ROUND(LEAST(v_metal_capacity, GREATEST(0, v_metal + v_metal_produced)), 6);
    projected_crystal := ROUND(LEAST(v_crystal_capacity, GREATEST(0, v_crystal + v_crystal_produced)), 6);
    projected_deuterium := ROUND(LEAST(v_deuterium_capacity, GREATEST(0, v_deuterium + v_deuterium_produced)), 6);
    RETURN NEXT;
END;
$function$;
