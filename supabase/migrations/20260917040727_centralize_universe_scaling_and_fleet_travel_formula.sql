-- Centraliza la evolución como scaling puro y unifica la fórmula de movimiento.
-- Orden semántico: rate clásico -> scaling de evolución -> bonuses posteriores.

CREATE OR REPLACE FUNCTION public.calculate_universe_scaling(p_evolution numeric)
RETURNS TABLE(
    resource_economy_scale numeric,
    resource_production_scale numeric,
    building_speed_scale numeric,
    research_speed_scale numeric,
    fleet_movement_scale numeric,
    lifeform_speed_scale numeric
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
    IF p_evolution IS NULL OR p_evolution <= 0 THEN
        RAISE EXCEPTION 'Universe evolution must be greater than zero: %', p_evolution;
    END IF;

    resource_economy_scale := power(p_evolution, 1.0);
    resource_production_scale := power(p_evolution, 1.0);
    building_speed_scale := power(p_evolution, 0.5);
    research_speed_scale := power(p_evolution, 0.5);
    fleet_movement_scale := power(p_evolution, 1.0 / 3.0);
    lifeform_speed_scale := power(p_evolution, 0.5);

    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_universe_scaling_at(
    p_universe_id uuid,
    p_at timestamptz
)
RETURNS TABLE(
    evolution numeric,
    resource_economy_scale numeric,
    resource_production_scale numeric,
    building_speed_scale numeric,
    research_speed_scale numeric,
    fleet_movement_scale numeric,
    lifeform_speed_scale numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_evolution numeric;
BEGIN
    v_evolution := public.calculate_universe_evolution_rate_at(p_universe_id, p_at);

    SELECT
        v_evolution,
        s.resource_economy_scale,
        s.resource_production_scale,
        s.building_speed_scale,
        s.research_speed_scale,
        s.fleet_movement_scale,
        s.lifeform_speed_scale
    INTO
        evolution,
        resource_economy_scale,
        resource_production_scale,
        building_speed_scale,
        research_speed_scale,
        fleet_movement_scale,
        lifeform_speed_scale
    FROM public.calculate_universe_scaling(v_evolution) s;

    RETURN NEXT;
END;
$$;

-- Canonical effective universe rates. The legacy column names remain for compatibility,
-- but their values now use the centralized scaling exponents above.
CREATE OR REPLACE FUNCTION public.calculate_universe_rates(p_universe_id uuid)
RETURNS TABLE(
    economy numeric,
    production numeric,
    building numeric,
    research numeric,
    fleet numeric,
    expedition numeric,
    lifeform numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_evolution numeric;
    v_economy_base numeric;
    v_production_base numeric;
    v_building_base numeric;
    v_research_base numeric;
    v_fleet_base numeric;
    v_expedition_base numeric;
    v_lifeform_base numeric;
    v_scaling record;
BEGIN
    SELECT
        public.calculate_universe_evolution_rate(p_universe_id),
        u.economy_speed,
        u.production_speed,
        u.building_speed,
        u.research_speed,
        u.fleet_speed,
        u.expedition_speed,
        u.lifeform_speed
    INTO
        v_evolution,
        v_economy_base,
        v_production_base,
        v_building_base,
        v_research_base,
        v_fleet_base,
        v_expedition_base,
        v_lifeform_base
    FROM public.universes u
    WHERE u.id = p_universe_id;

    IF v_economy_base IS NULL THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    SELECT * INTO v_scaling
    FROM public.calculate_universe_scaling(v_evolution);

    economy := v_economy_base * v_scaling.resource_economy_scale;
    production := v_production_base * v_scaling.resource_production_scale;
    building := v_building_base * v_scaling.building_speed_scale;
    research := v_research_base * v_scaling.research_speed_scale;
    fleet := v_fleet_base * v_scaling.fleet_movement_scale;
    -- Expeditions use the same movement scaling as every other fleet mission.
    expedition := v_expedition_base * v_scaling.fleet_movement_scale;
    lifeform := v_lifeform_base * v_scaling.lifeform_speed_scale;

    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_fleet_travel_time(
    p_distance numeric,
    p_ship_speed numeric,
    p_effective_fleet_rate numeric,
    p_speed_percent numeric DEFAULT 100
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_time numeric;
BEGIN
    IF p_distance < 0 THEN
        RAISE EXCEPTION 'Fleet distance cannot be negative: %', p_distance;
    END IF;
    IF p_ship_speed <= 0 THEN
        RAISE EXCEPTION 'Ship speed must be greater than zero: %', p_ship_speed;
    END IF;
    IF p_effective_fleet_rate <= 0 THEN
        RAISE EXCEPTION 'Effective fleet rate must be greater than zero: %', p_effective_fleet_rate;
    END IF;
    IF p_speed_percent <= 0 THEN
        RAISE EXCEPTION 'Speed percentage must be greater than zero: %', p_speed_percent;
    END IF;

    -- Canonical OGame-style non-linear duration.
    -- Our public API expresses speed as 100 = 100%; OGameX's internal
    -- implementation uses 10 for the same 100% setting.
    v_time := (
        (35000 / p_speed_percent) * sqrt(p_distance * 10 / p_ship_speed)
        + 10
    ) / p_effective_fleet_rate;

    RETURN round(greatest(v_time, 1), 4);
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_building_time(
    p_building_id text,
    p_target_level integer,
    p_universe_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_base_time numeric;
    v_time_factor numeric;
    v_building_speed numeric;
    v_scaling numeric;
    v_building_rate numeric;
BEGIN
    IF p_target_level < 1 THEN
        RAISE EXCEPTION 'El nivel objetivo debe ser >= 1';
    END IF;

    SELECT bd.base_build_time_seconds, bd.time_factor
    INTO v_base_time, v_time_factor
    FROM public.building_definitions bd
    WHERE bd.id = p_building_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El edificio % no existe', p_building_id;
    END IF;

    SELECT u.building_speed
    INTO v_building_speed
    FROM public.universes u
    WHERE u.id = p_universe_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El universo % no existe', p_universe_id;
    END IF;

    SELECT building_speed_scale
    INTO v_scaling
    FROM public.calculate_universe_scaling(
        public.calculate_universe_evolution_rate(p_universe_id)
    );

    v_building_rate := v_building_speed * v_scaling;

    IF v_building_rate <= 0 THEN
        RAISE EXCEPTION 'La velocidad efectiva de construcción es inválida: %', v_building_rate;
    END IF;

    RETURN round(
        (v_base_time * power(v_time_factor, p_target_level - 1)) / v_building_rate,
        4
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_research_time(
    p_research_id text,
    p_target_level integer,
    p_universe_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_base_time numeric;
    v_time_factor numeric;
    v_research_speed numeric;
    v_scaling numeric;
    v_research_rate numeric;
    v_max_level integer;
BEGIN
    IF p_target_level < 1 THEN
        RAISE EXCEPTION 'El nivel objetivo debe ser >= 1';
    END IF;

    SELECT rd.base_research_time_seconds, rd.time_factor, rd.max_level
    INTO v_base_time, v_time_factor, v_max_level
    FROM public.research_definitions rd
    WHERE rd.id = p_research_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La investigación % no existe', p_research_id;
    END IF;

    IF v_max_level IS NOT NULL AND p_target_level > v_max_level THEN
        RAISE EXCEPTION 'La investigación % no puede superar el nivel %', p_research_id, v_max_level;
    END IF;

    SELECT u.research_speed
    INTO v_research_speed
    FROM public.universes u
    WHERE u.id = p_universe_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El universo % no existe', p_universe_id;
    END IF;

    SELECT research_speed_scale
    INTO v_scaling
    FROM public.calculate_universe_scaling(
        public.calculate_universe_evolution_rate(p_universe_id)
    );

    v_research_rate := v_research_speed * v_scaling;

    RETURN round(
        (v_base_time * power(v_time_factor, p_target_level - 1)) / v_research_rate,
        4
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_ship_build_time(
    p_planet_id uuid,
    p_ship_id text
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_base_time numeric;
    v_shipyard_level integer;
    v_universe_id uuid;
    v_building_speed numeric;
    v_scaling numeric;
    v_building_rate numeric;
BEGIN
    SELECT p.universe_id INTO v_universe_id
    FROM public.planets p
    WHERE p.id = p_planet_id AND NOT p.is_destroyed;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Planet not found or destroyed';
    END IF;

    SELECT sd.base_build_time_seconds INTO v_base_time
    FROM public.ship_definitions sd
    WHERE sd.id = p_ship_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown ship: %', p_ship_id;
    END IF;

    SELECT COALESCE(pb.level, 0) INTO v_shipyard_level
    FROM public.planet_buildings pb
    WHERE pb.planet_id = p_planet_id
      AND pb.building_id = 'shipyard';

    SELECT u.building_speed INTO v_building_speed
    FROM public.universes u
    WHERE u.id = v_universe_id;

    SELECT building_speed_scale
    INTO v_scaling
    FROM public.calculate_universe_scaling(
        public.calculate_universe_evolution_rate(v_universe_id)
    );

    v_building_rate := v_building_speed * v_scaling;

    RETURN round(
        (v_base_time / greatest(v_shipyard_level, 1)) / v_building_rate,
        4
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_lifeform_building_time(
    p_planet_id uuid,
    p_building_id text,
    p_target_level integer
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_u uuid;
    v_rate numeric;
    v_scaling numeric;
    v_def public.lifeform_building_definitions%ROWTYPE;
    v_bonus numeric;
BEGIN
    SELECT universe_id INTO v_u FROM public.planets WHERE id = p_planet_id;
    IF v_u IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;
    SELECT * INTO v_def FROM public.lifeform_building_definitions WHERE id = p_building_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Building % does not exist', p_building_id; END IF;
    SELECT lifeform_speed INTO v_rate FROM public.universes WHERE id = v_u;
    SELECT lifeform_speed_scale INTO v_scaling
    FROM public.calculate_universe_scaling(public.calculate_universe_evolution_rate(v_u));
    v_bonus := public.get_planet_lifeform_building_effect(p_planet_id, 'building_speed_percent');
    RETURN round(
        (v_def.base_build_time_seconds * power(v_def.time_factor, p_target_level - 1))
        / (v_rate * v_scaling * (1 + v_bonus / 100)),
        4
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_lifeform_research_time(
    p_planet_id uuid,
    p_research_id text,
    p_target_level integer
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_u uuid;
    v_player uuid;
    v_rate numeric;
    v_scaling numeric;
    v_def public.lifeform_research_definitions%ROWTYPE;
    v_bonus numeric;
BEGIN
    SELECT universe_id, player_id INTO v_u, v_player FROM public.planets WHERE id = p_planet_id;
    IF v_u IS NULL THEN RAISE EXCEPTION 'Planet % does not exist', p_planet_id; END IF;
    SELECT * INTO v_def FROM public.lifeform_research_definitions WHERE id = p_research_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Research % does not exist', p_research_id; END IF;
    SELECT lifeform_speed INTO v_rate FROM public.universes WHERE id = v_u;
    SELECT lifeform_speed_scale INTO v_scaling
    FROM public.calculate_universe_scaling(public.calculate_universe_evolution_rate(v_u));
    v_bonus := public.get_active_lifeform_research_effect(v_player, 'research_speed_percent');
    RETURN round(
        (v_def.base_research_time_seconds * power(v_def.time_factor, p_target_level - 1))
        / (v_rate * v_scaling * (1 + v_bonus / 100)),
        4
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_fleet_time(
    p_origin_planet_id uuid,
    p_destination_planet_id uuid,
    p_ship_id text,
    p_quantity bigint DEFAULT 1
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_distance numeric;
    v_ship_speed numeric;
    v_universe_id uuid;
    v_fleet_speed numeric;
    v_evolution numeric;
    v_fleet_scale numeric;
    v_bonus numeric := 1;
    v_time numeric;
    v_player_id uuid;
BEGIN
    IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;

    SELECT universe_id, player_id INTO v_universe_id, v_player_id
    FROM public.planets
    WHERE id = p_origin_planet_id AND NOT is_destroyed;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found or destroyed'; END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.planets
        WHERE id = p_destination_planet_id AND NOT is_destroyed
    ) THEN
        RAISE EXCEPTION 'Destination planet not found or destroyed';
    END IF;

    SELECT speed INTO v_ship_speed FROM public.ship_definitions WHERE id = p_ship_id;
    IF NOT FOUND OR v_ship_speed <= 0 THEN RAISE EXCEPTION 'Ship has invalid speed'; END IF;

    SELECT fleet_speed INTO v_fleet_speed FROM public.universes WHERE id = v_universe_id;
    IF v_fleet_speed IS NULL OR v_fleet_speed <= 0 THEN RAISE EXCEPTION 'Invalid universe fleet speed'; END IF;

    v_evolution := public.calculate_universe_evolution_rate(v_universe_id);
    SELECT fleet_movement_scale INTO v_fleet_scale
    FROM public.calculate_universe_scaling(v_evolution);

    v_bonus := public.get_player_fleet_speed_multiplier(v_player_id, p_origin_planet_id);
    v_distance := public.calculate_fleet_distance(p_origin_planet_id, p_destination_planet_id);

    -- Classic universe fleet rate -> universe evolution scaling -> player bonuses.
    v_time := public.calculate_fleet_travel_time(
        v_distance,
        v_ship_speed,
        v_fleet_speed * v_fleet_scale * v_bonus,
        100
    );

    RETURN v_time;
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_time(
    p_origin_planet_id uuid,
    p_ship_id text,
    p_quantity bigint DEFAULT 1
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_universe_id uuid;
    v_ship_speed numeric;
    v_expedition_speed numeric;
    v_evolution numeric;
    v_fleet_scale numeric;
    v_bonus numeric := 1;
    v_distance numeric;
BEGIN
    IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be greater than 0'; END IF;
    SELECT p.universe_id INTO v_universe_id
    FROM public.planets p
    WHERE p.id = p_origin_planet_id AND NOT p.is_destroyed;
    IF NOT FOUND THEN RAISE EXCEPTION 'Origin planet not found or destroyed'; END IF;

    SELECT sd.speed INTO v_ship_speed FROM public.ship_definitions sd WHERE sd.id = p_ship_id;
    IF NOT FOUND OR v_ship_speed <= 0 THEN RAISE EXCEPTION 'Invalid expedition ship: %', p_ship_id; END IF;

    SELECT u.expedition_speed INTO v_expedition_speed
    FROM public.universes u WHERE u.id = v_universe_id;
    IF v_expedition_speed IS NULL OR v_expedition_speed <= 0 THEN RAISE EXCEPTION 'Invalid universe expedition speed'; END IF;

    v_evolution := public.calculate_universe_evolution_rate(v_universe_id);
    SELECT fleet_movement_scale INTO v_fleet_scale
    FROM public.calculate_universe_scaling(v_evolution);

    v_bonus := public.get_player_fleet_speed_multiplier(
        (SELECT player_id FROM public.planets WHERE id = p_origin_planet_id),
        p_origin_planet_id
    );
    v_distance := public.calculate_expedition_distance(p_origin_planet_id);

    -- Expeditions use the same movement evolution scaling as normal fleets.
    RETURN public.calculate_fleet_travel_time(
        v_distance,
        v_ship_speed,
        v_expedition_speed * v_fleet_scale * v_bonus,
        100
    );
END;
$$;

-- Keep expedition delay on the same fleet movement evolution scale.
CREATE OR REPLACE FUNCTION public.calculate_expedition_delay_seconds(
    p_fleet_id uuid,
    p_multiplier numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_universe_id uuid;
    v_fleet_speed numeric;
    v_evolution numeric;
    v_fleet_scale numeric;
    v_fleet_rate numeric;
    v_holding_seconds numeric := 3600;
    v_additional_delay numeric;
    v_arrives_at timestamptz;
BEGIN
    IF p_multiplier NOT IN (2,3,5) THEN RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5'; END IF;
    SELECT p.universe_id, fm.arrives_at
    INTO v_universe_id, v_arrives_at
    FROM public.fleet_movements fm
    JOIN public.planets p ON p.id = fm.origin_planet_id
    WHERE fm.id = p_fleet_id AND fm.mission_type = 'EXPEDITION';
    IF NOT FOUND THEN RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id; END IF;

    SELECT u.fleet_speed INTO v_fleet_speed FROM public.universes u WHERE u.id = v_universe_id;
    IF v_fleet_speed IS NULL OR v_fleet_speed <= 0 THEN RAISE EXCEPTION 'Invalid universe fleet speed for expedition %', p_fleet_id; END IF;

    v_evolution := public.calculate_universe_evolution_rate_at(v_universe_id, v_arrives_at);
    SELECT fleet_movement_scale INTO v_fleet_scale
    FROM public.calculate_universe_scaling(v_evolution);
    v_fleet_rate := v_fleet_speed * v_fleet_scale;
    v_additional_delay := floor((v_holding_seconds * p_multiplier) / v_fleet_rate);
    RETURN greatest(v_additional_delay, 1);
END;
$$;
