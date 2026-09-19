CREATE INDEX IF NOT EXISTS idx_research_queue_player_researching_finish
ON public.research_queue (player_id, finishes_at, created_at)
WHERE UPPER(status) = 'RESEARCHING';

CREATE OR REPLACE FUNCTION public.process_research_queue_for_player(p_player_id uuid)
RETURNS TABLE(
    queue_id uuid,
    player_id uuid,
    research_id text,
    completed_level integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue record;
    v_completed boolean;
BEGIN
    FOR v_queue IN
        SELECT
            rq.id,
            rq.player_id,
            rq.research_id,
            rq.target_level
        FROM public.research_queue AS rq
        WHERE rq.player_id = p_player_id
          AND UPPER(rq.status) = 'RESEARCHING'
          AND rq.finishes_at <= now()
        ORDER BY rq.finishes_at ASC, rq.created_at ASC
        FOR UPDATE OF rq SKIP LOCKED
    LOOP
        v_completed := public.complete_research(v_queue.id);

        IF v_completed THEN
            queue_id := v_queue.id;
            player_id := v_queue.player_id;
            research_id := v_queue.research_id;
            completed_level := v_queue.target_level;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_planet_tick(p_planet_id uuid)
RETURNS TABLE(
    planet_id uuid,
    metal numeric,
    crystal numeric,
    deuterium numeric,
    energy numeric,
    buildings_completed integer,
    researches_completed integer
)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_result record;
    v_player_id uuid;
    v_buildings_completed integer := 0;
    v_researches_completed integer := 0;
begin
    select p.player_id
    into v_player_id
    from public.planets p
    where p.id = p_planet_id;

    select * into v_result
    from public.process_planet_tick_local(p_planet_id);

    select count(*)
    into v_buildings_completed
    from public.process_building_queue_for_planet(p_planet_id) b;

    if v_player_id is not null then
        select count(*)
        into v_researches_completed
        from public.process_research_queue_for_player(v_player_id) r;
    end if;

    return query
    select
        v_result.planet_id,
        v_result.metal,
        v_result.crystal,
        v_result.deuterium,
        v_result.energy,
        v_buildings_completed,
        v_researches_completed;
end;
$function$;