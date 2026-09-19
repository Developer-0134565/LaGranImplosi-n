CREATE OR REPLACE FUNCTION public.process_shipyard_queue()
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, status text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_queue RECORD;
    v_result_ship_id text;
    v_result_quantity bigint;
BEGIN
    FOR v_queue IN
        SELECT
            sq.id,
            sq.planet_id,
            sq.ship_id AS queued_ship_id,
            sq.quantity AS queued_quantity,
            sq.finishes_at
        FROM public.shipyard_queue AS sq
        WHERE sq.status = 'BUILDING'
          AND sq.finishes_at <= now()
        ORDER BY sq.created_at
        FOR UPDATE SKIP LOCKED
    LOOP
        INSERT INTO public.planet_ships AS ps (planet_id, ship_id, quantity)
        VALUES (v_queue.planet_id, v_queue.queued_ship_id, v_queue.queued_quantity)
        ON CONFLICT ON CONSTRAINT planet_ships_pkey
        DO UPDATE SET quantity = ps.quantity + EXCLUDED.quantity;

        UPDATE public.shipyard_queue AS sq
        SET status = 'COMPLETED'
        WHERE sq.id = v_queue.id
          AND sq.status = 'BUILDING';

        queue_id := v_queue.id;
        ship_id := v_queue.queued_ship_id;
        quantity := v_queue.queued_quantity;
        status := 'COMPLETED';

        RETURN NEXT;
    END LOOP;
END;
$function$;