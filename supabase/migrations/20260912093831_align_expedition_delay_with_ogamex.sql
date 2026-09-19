CREATE OR REPLACE FUNCTION public.select_expedition_delay_multiplier()
RETURNS numeric
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_roll numeric;
BEGIN
    -- OGameX: 89% x2, 10% x3, 1% x5.
    v_roll := random() * 100;

    IF v_roll < 89 THEN
        RETURN 2;
    ELSIF v_roll < 99 THEN
        RETURN 3;
    ELSE
        RETURN 5;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_delay_seconds(
    p_fleet_id uuid,
    p_multiplier numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_universe_id uuid;
    v_fleet_speed numeric;
    v_holding_seconds numeric := 3600;
    v_additional_delay numeric;
BEGIN
    IF p_multiplier NOT IN (2, 3, 5) THEN
        RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5';
    END IF;

    SELECT p.universe_id
    INTO v_universe_id
    FROM public.fleet_movements fm
    JOIN public.planets p
      ON p.id = fm.origin_planet_id
    WHERE fm.id = p_fleet_id
      AND fm.mission_type = 'EXPEDITION';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expedition fleet % not found', p_fleet_id;
    END IF;

    SELECT u.fleet_speed
    INTO v_fleet_speed
    FROM public.universes u
    WHERE u.id = v_universe_id;

    IF v_fleet_speed IS NULL OR v_fleet_speed <= 0 THEN
        RAISE EXCEPTION 'Invalid universe fleet speed for expedition %', p_fleet_id;
    END IF;

    /*
      OGameX current implementation:
        baseAdditionalReturnTripTime = time_holding * multiplier
        additionalReturnTripTime = intdiv(baseAdditionalReturnTripTime, fleetSpeedPeaceful)

      Our expedition engine currently uses the canonical 1-hour minimum/default
      holding time. The holding duration itself is not reduced by fleet speed;
      only the delay modifier is divided by peaceful fleet speed.
    */
    v_additional_delay :=
        floor((v_holding_seconds * p_multiplier) / v_fleet_speed);

    RETURN greatest(v_additional_delay, 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_expedition_total_hold_seconds(
    p_fleet_id uuid,
    p_multiplier numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF p_multiplier NOT IN (2, 3, 5) THEN
        RAISE EXCEPTION 'Delay multiplier must be 2, 3 or 5';
    END IF;

    RETURN public.calculate_expedition_delay_seconds(
        p_fleet_id,
        p_multiplier
    );
END;
$function$;