CREATE OR REPLACE FUNCTION public.calculate_universe_rates(p_universe_id uuid)
RETURNS TABLE(economy numeric, production numeric, building numeric, research numeric, fleet numeric, expedition numeric, lifeform numeric)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_evolution numeric;
    v_economy_base numeric;
    v_production_base numeric;
    v_building_base numeric;
    v_research_base numeric;
    v_fleet_base numeric;
    v_expedition_base numeric;
    v_lifeform_base numeric;
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
    FROM public.universes AS u
    WHERE u.id = p_universe_id;

    IF v_economy_base IS NULL THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    /*
     * The universe evolution multiplier is applied after each classic
     * universe modifier.  No hidden sqrt/cuberoot dampening is introduced:
     * every rate path sees the same current evolution state.
     */
    economy := v_economy_base * v_evolution;
    production := v_production_base * v_evolution;
    building := v_building_base * v_evolution;
    research := v_research_base * v_evolution;
    fleet := v_fleet_base * v_evolution;
    expedition := v_expedition_base * v_evolution;
    lifeform := v_lifeform_base * v_evolution;

    RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_universe_heartbeat()
RETURNS TABLE(universes_processed integer, total_ticks_executed integer, systems_expanded integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe RECORD;
    v_clock RECORD;
    v_roll RECORD;
    v_expansion RECORD;
    v_population RECORD;
    v_universes integer := 0;
    v_ticks integer := 0;
    v_systems integer := 0;
    v_population_due boolean;
BEGIN
    FOR v_universe IN
        SELECT id
        FROM public.universes
        WHERE is_active = true
        ORDER BY created_at, id
    LOOP
        BEGIN
            SELECT * INTO v_clock
            FROM public.process_universe_clock(v_universe.id);

            v_universes := v_universes + 1;
            v_ticks := v_ticks + COALESCE(v_clock.ticks_executed, 0);

            IF EXISTS (
                SELECT 1
                FROM public.universe_expansion_state
                WHERE universe_id = v_universe.id
            ) THEN
                SELECT * INTO v_roll
                FROM public.process_universe_galaxy_roll(v_universe.id);

                SELECT * INTO v_expansion
                FROM public.process_universe_system_expansion(v_universe.id);

                v_systems := v_systems + COALESCE(v_expansion.systems_expanded, 0);

                /*
                 * A newly unlocked galaxy/system must participate in AI
                 * population reconciliation immediately.  The five-minute
                 * reconciliation cadence remains the fallback for ordinary
                 * population drift, but universe expansion is an explicit
                 * population event and should not wait for the next cadence.
                 */
                IF COALESCE(v_roll.galaxies_created, 0) > 0
                   OR COALESCE(v_expansion.systems_expanded, 0) > 0 THEN
                    SELECT * INTO v_population
                    FROM public.reconcile_universe_ai_population(v_universe.id);
                END IF;
            END IF;

            SELECT EXISTS (
                SELECT 1
                FROM public.universe_population_state
                WHERE universe_id = v_universe.id
                  AND next_reconciliation_at <= now()
            ) INTO v_population_due;

            IF v_population_due THEN
                SELECT * INTO v_population
                FROM public.reconcile_universe_ai_population(v_universe.id);
            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Universe heartbeat failed for %: % (%)',
                v_universe.id, SQLERRM, SQLSTATE;
        END;
    END LOOP;

    RETURN QUERY
    SELECT v_universes, v_ticks, v_systems;
END;
$function$;