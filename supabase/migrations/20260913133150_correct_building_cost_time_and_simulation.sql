CREATE OR REPLACE FUNCTION public.calculate_building_time(p_building_id text, p_target_level integer, p_universe_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_metal numeric;
    v_crystal numeric;
    v_building_speed numeric;
    v_duration numeric;
BEGIN
    IF p_target_level < 1 THEN
        RAISE EXCEPTION 'El nivel objetivo debe ser >= 1';
    END IF;

    SELECT c.metal, c.crystal
    INTO v_metal, v_crystal
    FROM public.calculate_building_cost(p_building_id, p_target_level) c;

    SELECT u.building_speed
    INTO v_building_speed
    FROM public.universes u
    WHERE u.id = p_universe_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El universo % no existe', p_universe_id;
    END IF;

    IF v_building_speed IS NULL OR v_building_speed <= 0 THEN
        RAISE EXCEPTION 'La velocidad de construcción es inválida: %', v_building_speed;
    END IF;

    /* OGame: (metal + crystal) / 2500 horas, ajustado por velocidad.
       Robotics/Nanites se incorporarán aquí cuando esas facilities formen
       parte del catálogo económico; actualmente no existen en building_definitions. */
    v_duration :=
        ((v_metal + v_crystal) * 3600)
        / (2500 * v_building_speed);

    RETURN GREATEST(1, round(v_duration, 4));
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_building_production_delta(p_planet_id uuid, p_building_id text)
RETURNS TABLE(building_id text, current_level integer, target_level integer, metal_delta_per_hour numeric, crystal_delta_per_hour numeric, deuterium_delta_per_hour numeric, energy_delta_per_hour numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_current_level integer := 0;
    v_target_level integer;
    v_current numeric := 0;
    v_target numeric := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.planets
        WHERE id = p_planet_id AND is_destroyed = false
    ) THEN
        RAISE EXCEPTION 'Planet % does not exist or is destroyed', p_planet_id;
    END IF;

    SELECT COALESCE(MAX(pb.level), 0)
    INTO v_current_level
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id
      AND pb.building_id = p_building_id;

    v_target_level := v_current_level + 1;

    IF p_building_id = 'metal_mine' THEN
        v_current := 30 * v_current_level * power(1.1, v_current_level);
        v_target := 30 * v_target_level * power(1.1, v_target_level);
    ELSIF p_building_id = 'crystal_mine' THEN
        v_current := 20 * v_current_level * power(1.1, v_current_level);
        v_target := 20 * v_target_level * power(1.1, v_target_level);
    ELSIF p_building_id = 'deuterium_synthesizer' THEN
        v_current := 10 * v_current_level * power(1.1, v_current_level);
        v_target := 10 * v_target_level * power(1.1, v_target_level);
    ELSIF p_building_id = 'solar_plant' THEN
        v_current := 20 * v_current_level * power(1.1, v_current_level);
        v_target := 20 * v_target_level * power(1.1, v_target_level);
    ELSE
        RAISE EXCEPTION 'Building % does not directly produce resources', p_building_id;
    END IF;

    /* Live universe rates apply to resource production, but NOT solar energy. */
    IF p_building_id <> 'solar_plant' THEN
        SELECT v_current * r.economy_rate * r.production_rate,
               v_target * r.economy_rate * r.production_rate
        INTO v_current, v_target
        FROM public.calculate_universe_rates(
            (SELECT universe_id FROM public.planets WHERE id = p_planet_id)
        ) r;
    END IF;

    building_id := p_building_id;
    current_level := v_current_level;
    target_level := v_target_level;
    metal_delta_per_hour := 0;
    crystal_delta_per_hour := 0;
    deuterium_delta_per_hour := 0;
    energy_delta_per_hour := 0;

    CASE p_building_id
        WHEN 'metal_mine' THEN metal_delta_per_hour := v_target - v_current;
        WHEN 'crystal_mine' THEN crystal_delta_per_hour := v_target - v_current;
        WHEN 'deuterium_synthesizer' THEN deuterium_delta_per_hour := v_target - v_current;
        WHEN 'solar_plant' THEN energy_delta_per_hour := v_target - v_current;
    END CASE;

    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.simulate_building_step(p_planet_id uuid, p_building_id text, p_virtual_level integer, p_metal numeric, p_crystal numeric, p_deuterium numeric, p_metal_per_hour numeric, p_crystal_per_hour numeric, p_deuterium_per_hour numeric, p_energy_per_hour numeric)
RETURNS TABLE(building_id text, current_level integer, target_level integer, duration_seconds numeric, starting_metal numeric, starting_crystal numeric, starting_deuterium numeric, cost_metal numeric, cost_crystal numeric, cost_deuterium numeric, affordable boolean, completion_metal numeric, completion_crystal numeric, completion_deuterium numeric, resulting_metal numeric, resulting_crystal numeric, resulting_deuterium numeric, current_metal_per_hour numeric, resulting_metal_per_hour numeric, current_crystal_per_hour numeric, resulting_crystal_per_hour numeric, current_deuterium_per_hour numeric, resulting_deuterium_per_hour numeric, current_energy_per_hour numeric, resulting_energy_per_hour numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_target_level integer;
    v_cost_metal numeric;
    v_cost_crystal numeric;
    v_cost_deuterium numeric;
    v_duration numeric;
    v_result_metal numeric;
    v_result_crystal numeric;
    v_result_deuterium numeric;
    v_result_metal_hour numeric := p_metal_per_hour;
    v_result_crystal_hour numeric := p_crystal_per_hour;
    v_result_deuterium_hour numeric := p_deuterium_per_hour;
    v_result_energy_hour numeric := p_energy_per_hour;
    v_universe_id uuid;
    v_rates record;
BEGIN
    IF p_virtual_level < 0 THEN
        RAISE EXCEPTION 'Nivel virtual inválido: %', p_virtual_level;
    END IF;

    SELECT p.universe_id INTO v_universe_id
    FROM public.planets p
    WHERE p.id = p_planet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Planeta % no encontrado', p_planet_id;
    END IF;

    v_target_level := p_virtual_level + 1;

    SELECT c.metal, c.crystal, c.deuterium
    INTO v_cost_metal, v_cost_crystal, v_cost_deuterium
    FROM public.calculate_building_cost(p_building_id, v_target_level) c;

    v_duration := public.calculate_building_time(p_building_id, v_target_level, v_universe_id);

    v_result_metal := p_metal - v_cost_metal + p_metal_per_hour * v_duration / 3600;
    v_result_crystal := p_crystal - v_cost_crystal + p_crystal_per_hour * v_duration / 3600;
    v_result_deuterium := p_deuterium - v_cost_deuterium + p_deuterium_per_hour * v_duration / 3600;

    affordable := p_metal >= v_cost_metal AND p_crystal >= v_cost_crystal AND p_deuterium >= v_cost_deuterium;

    SELECT * INTO v_rates FROM public.get_planet_economic_rates(p_planet_id);

    IF p_building_id = 'metal_mine' THEN
        v_result_metal_hour := 30 * v_target_level * power(1.1, v_target_level) * v_rates.economy_rate * v_rates.production_rate;
    ELSIF p_building_id = 'crystal_mine' THEN
        v_result_crystal_hour := 20 * v_target_level * power(1.1, v_target_level) * v_rates.economy_rate * v_rates.production_rate;
    ELSIF p_building_id = 'deuterium_synthesizer' THEN
        v_result_deuterium_hour := 10 * v_target_level * power(1.1, v_target_level) * v_rates.economy_rate * v_rates.production_rate;
    ELSIF p_building_id = 'solar_plant' THEN
        v_result_energy_hour := 20 * v_target_level * power(1.1, v_target_level);
    END IF;

    RETURN QUERY SELECT
        p_building_id, p_virtual_level, v_target_level, v_duration,
        p_metal, p_crystal, p_deuterium,
        v_cost_metal, v_cost_crystal, v_cost_deuterium,
        affordable,
        p_metal + p_metal_per_hour * v_duration / 3600,
        p_crystal + p_crystal_per_hour * v_duration / 3600,
        p_deuterium + p_deuterium_per_hour * v_duration / 3600,
        v_result_metal, v_result_crystal, v_result_deuterium,
        p_metal_per_hour, v_result_metal_hour,
        p_crystal_per_hour, v_result_crystal_hour,
        p_deuterium_per_hour, v_result_deuterium_hour,
        p_energy_per_hour, v_result_energy_hour;
END;
$function$;