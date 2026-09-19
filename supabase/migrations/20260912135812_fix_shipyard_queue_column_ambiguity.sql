CREATE OR REPLACE FUNCTION public.process_shipyard_queue()
RETURNS TABLE(queue_id uuid, ship_id text, quantity bigint, status text)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_queue RECORD;
BEGIN
    FOR v_queue IN
        SELECT
            sq.id,
            sq.planet_id,
            sq.ship_id,
            sq.quantity,
            sq.finishes_at
        FROM public.shipyard_queue AS sq
        WHERE sq.status = 'BUILDING'
          AND sq.finishes_at <= now()
        ORDER BY sq.created_at
        FOR UPDATE SKIP LOCKED
    LOOP
        INSERT INTO public.planet_ships AS ps (planet_id, ship_id, quantity)
        VALUES (v_queue.planet_id, v_queue.ship_id, v_queue.quantity)
        ON CONFLICT (planet_id, ship_id)
        DO UPDATE SET quantity = ps.quantity + EXCLUDED.quantity;

        UPDATE public.shipyard_queue AS sq
        SET status = 'COMPLETED'
        WHERE sq.id = v_queue.id
          AND sq.status = 'BUILDING';

        queue_id := v_queue.id;
        ship_id := v_queue.ship_id;
        quantity := v_queue.quantity;
        status := 'COMPLETED';

        RETURN NEXT;
    END LOOP;
END;
$function$;