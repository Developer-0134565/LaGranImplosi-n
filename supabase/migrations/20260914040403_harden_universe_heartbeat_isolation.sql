CREATE OR REPLACE FUNCTION public.process_universe_heartbeat()
RETURNS TABLE(universes_processed integer, total_ticks_executed integer, systems_expanded integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe RECORD;
    v_clock RECORD;
    v_expansion RECORD;
    v_population RECORD;
    v_universes integer := 0;
    v_ticks integer := 0;
    v_systems integer := 0;
BEGIN
    FOR v_universe IN
        SELECT id
        FROM public.universes
        WHERE is_active = true
        ORDER BY created_at, id
    LOOP
        -- Each universe gets its own subtransaction. A broken legacy/test
        -- universe or a transient per-universe error must never stop the
        -- production universe from advancing.
        BEGIN
            SELECT *
            INTO v_clock
            FROM public.process_universe_clock(v_universe.id);

            v_universes := v_universes + 1;
            v_ticks := v_ticks + COALESCE(v_clock.ticks_executed, 0);

            IF EXISTS (
                SELECT 1
                FROM public.universe_expansion_state
                WHERE universe_id = v_universe.id
            ) THEN
                PERFORM public.process_universe_galaxy_roll(v_universe.id);

                SELECT *
                INTO v_expansion
                FROM public.process_universe_system_expansion(v_universe.id);

                v_systems := v_systems + COALESCE(v_expansion.systems_expanded, 0);
            END IF;

            -- Population is timestamp-driven. Universes without population
            -- state (legacy/test) are intentionally skipped until initialized.
            IF EXISTS (
                SELECT 1
                FROM public.universe_population_state
                WHERE universe_id = v_universe.id
                  AND next_reconciliation_at <= now()
            ) THEN
                SELECT *
                INTO v_population
                FROM public.reconcile_universe_ai_population(v_universe.id);
            END IF;

        EXCEPTION WHEN OTHERS THEN
            -- Keep the heartbeat alive for every other universe. The warning
            -- remains visible in PostgreSQL/pg_cron logs for later audit.
            RAISE WARNING 'Universe heartbeat failed for %: % (%)',
                v_universe.id, SQLERRM, SQLSTATE;
        END;
    END LOOP;

    RETURN QUERY
    SELECT v_universes, v_ticks, v_systems;
END;
$function$;