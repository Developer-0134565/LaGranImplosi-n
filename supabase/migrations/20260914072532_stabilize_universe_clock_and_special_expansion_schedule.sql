-- Universe evolution is timestamp-driven. A heartbeat does not need to replay every
-- historical 1-second tick. Replay the due event sweep once; each subsystem catches
-- up from its own persisted timestamps.
CREATE OR REPLACE FUNCTION public.process_universe_clock(p_universe_id uuid)
RETURNS TABLE(tick_processed boolean, ticks_executed integer, next_tick_at timestamptz)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_clock public.universe_clock%ROWTYPE;
    v_now timestamptz := now();
    v_due_ticks bigint;
    v_next_tick timestamptz;
    v_interval interval;
BEGIN
    SELECT * INTO v_clock
    FROM public.universe_clock
    WHERE universe_id = p_universe_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Universe clock not found: %', p_universe_id;
    END IF;

    IF v_clock.is_processing THEN
        RETURN QUERY SELECT false, 0, v_clock.next_tick_at;
        RETURN;
    END IF;

    IF v_clock.tick_interval_seconds <= 0 THEN
        RAISE EXCEPTION 'Invalid tick interval for universe %', p_universe_id;
    END IF;

    IF v_clock.next_tick_at > v_now THEN
        RETURN QUERY SELECT false, 0, v_clock.next_tick_at;
        RETURN;
    END IF;

    v_interval := make_interval(secs => v_clock.tick_interval_seconds);
    v_due_ticks := GREATEST(
        1,
        floor(extract(epoch FROM (v_now - v_clock.next_tick_at)) / v_clock.tick_interval_seconds)::bigint + 1
    );

    UPDATE public.universe_clock
    SET is_processing = true,
        updated_at = v_now
    WHERE universe_id = p_universe_id;

    -- One authoritative sweep is enough. Resources, queues, population and
    -- universe expansion all use persisted timestamps and perform their own
    -- catch-up. Replaying thousands of historical ticks would only multiply
    -- work without changing the result.
    PERFORM public.process_universe_tick(p_universe_id);

    v_next_tick := v_now + v_interval;

    UPDATE public.universe_clock
    SET last_tick_at = v_now,
        next_tick_at = v_next_tick,
        is_processing = false,
        updated_at = v_now
    WHERE universe_id = p_universe_id;

    RETURN QUERY SELECT true, 1, v_next_tick;

EXCEPTION
    WHEN OTHERS THEN
        UPDATE public.universe_clock
        SET is_processing = false,
            updated_at = now()
        WHERE universe_id = p_universe_id;
        RAISE;
END;
$function$;

-- Special galaxies: after their initial 10 systems, every newly created
-- system pushes the NEXT interval by +5%. The old implementation updated the
-- interval but scheduled the next event using the old interval.
CREATE OR REPLACE FUNCTION public.process_universe_system_expansion(p_universe_id uuid)
RETURNS TABLE(systems_expanded integer, last_galaxy integer, last_system_count integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_now timestamptz := now();
    v_galaxy public.universe_galaxies%ROWTYPE;
    v_new_interval numeric;
    v_next_expansion_at timestamptz;
    v_system_count integer;
    v_expanded integer := 0;
    v_last_galaxy integer := NULL;
    v_last_system_count integer := NULL;
    v_max_expansions integer := 10000;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.universes WHERE id = p_universe_id) THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    WHILE v_expanded < v_max_expansions LOOP
        SELECT * INTO v_galaxy
        FROM public.universe_galaxies
        WHERE universe_id = p_universe_id
          AND next_system_expansion_at <= v_now
          AND system_count < 1000000000
        ORDER BY next_system_expansion_at ASC, galaxy ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1;

        EXIT WHEN NOT FOUND;

        v_system_count := v_galaxy.system_count + 1;

        IF v_galaxy.is_special THEN
            v_new_interval := GREATEST(1, v_galaxy.system_interval_seconds)
                * GREATEST(1, v_galaxy.system_interval_growth_factor);
            v_next_expansion_at := v_galaxy.next_system_expansion_at
                + make_interval(secs => v_new_interval);
        ELSE
            v_new_interval := v_galaxy.system_interval_seconds;
            v_next_expansion_at := v_galaxy.next_system_expansion_at
                + make_interval(secs => v_new_interval);
        END IF;

        UPDATE public.universe_galaxies
        SET system_count = v_system_count,
            next_system_expansion_at = v_next_expansion_at,
            system_interval_seconds = v_new_interval,
            updated_at = v_now
        WHERE universe_id = v_galaxy.universe_id
          AND galaxy = v_galaxy.galaxy;

        v_expanded := v_expanded + 1;
        v_last_galaxy := v_galaxy.galaxy;
        v_last_system_count := v_system_count;
    END LOOP;

    RETURN QUERY SELECT v_expanded, v_last_galaxy, v_last_system_count;
END;
$function$;

-- One-minute heartbeat is sufficient because every important universe event is
-- timestamp based and catches up after downtime. This avoids executing the
-- complete planet sweep every second.
DO $do$
BEGIN
    PERFORM cron.unschedule(3);
    PERFORM cron.schedule(
        'universe-heartbeat',
        '* * * * *',
        'SELECT public.process_universe_heartbeat();'
    );
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Could not reschedule universe heartbeat: %', SQLERRM;
END;
$do$;

UPDATE public.universe_clock
SET tick_interval_seconds = 60,
    next_tick_at = GREATEST(next_tick_at, now()),
    updated_at = now()
WHERE tick_interval_seconds < 60;