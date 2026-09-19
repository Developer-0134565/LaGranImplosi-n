CREATE OR REPLACE FUNCTION public.process_research_queue_for_universe(p_universe_id uuid)
RETURNS TABLE(queue_id uuid, player_id uuid, research_id text, completed_level integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_queue RECORD;
    v_completed boolean;
    v_level integer;
BEGIN
    FOR v_queue IN
        SELECT rq.id, rq.player_id, rq.research_id, rq.target_level
        FROM public.research_queue AS rq
        WHERE EXISTS (
            SELECT 1
            FROM public.planets AS p
            WHERE p.player_id = rq.player_id
              AND p.universe_id = p_universe_id
              AND NOT p.is_destroyed
        )
          AND UPPER(rq.status) = 'RESEARCHING'
          AND rq.finishes_at <= now()
        ORDER BY rq.finishes_at ASC
        FOR UPDATE OF rq SKIP LOCKED
    LOOP
        v_completed := public.complete_research(v_queue.id);
        IF v_completed THEN
            v_level := v_queue.target_level;
            queue_id := v_queue.id;
            player_id := v_queue.player_id;
            research_id := v_queue.research_id;
            completed_level := v_level;
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$function$;