DROP INDEX IF EXISTS public.planet_defenses_planet_defense_unique;
ALTER TABLE public.planet_defenses ADD CONSTRAINT planet_defenses_planet_defense_unique UNIQUE (planet_id, defense_id);

CREATE OR REPLACE FUNCTION public.process_defense_queue(p_planet_id uuid)
RETURNS TABLE(queue_id uuid, defense_id text, quantity bigint, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE v_queue RECORD;
BEGIN
  FOR v_queue IN
    SELECT dq.id,dq.planet_id,dq.defense_id AS queued_defense_id,dq.quantity AS queued_quantity
    FROM public.defense_queue dq
    WHERE dq.planet_id=p_planet_id AND dq.status='BUILDING' AND dq.finishes_at<=now()
    ORDER BY dq.created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    INSERT INTO public.planet_defenses (planet_id,defense_id,quantity,updated_at)
    VALUES(v_queue.planet_id,v_queue.queued_defense_id,v_queue.queued_quantity,now())
    ON CONFLICT ON CONSTRAINT planet_defenses_planet_defense_unique
    DO UPDATE SET quantity=public.planet_defenses.quantity+EXCLUDED.quantity,updated_at=now();
    UPDATE public.defense_queue dq SET status='COMPLETED' WHERE dq.id=v_queue.id AND dq.status='BUILDING';
    queue_id:=v_queue.id; defense_id:=v_queue.queued_defense_id; quantity:=v_queue.queued_quantity; status:='COMPLETED'; RETURN NEXT;
  END LOOP;
END;
$$;