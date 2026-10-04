-- =============================================================================
-- FLEET SLOTS â€” serializaciÃ³n por JUGADOR (misiÃ³n 2026-10-03)
-- =============================================================================
-- QUE SE CORREGIÃ“
--   La polÃ­tica de slots YA estaba decidida e implementada (no era un product decision):
--       max_slots = 1 + computer_technology
--       ocupado   = todo fleet_movement cuyo status NO sea COMPLETED ni CANCELLED
--       liberado  = al pasar a COMPLETED o CANCELLED
--   y ya se imponÃ­a con un trigger BEFORE INSERT (trg_enforce_fleet_slots) sobre
--   fleet_movements, que ademÃ¡s cubre TODOS los caminos de inserciÃ³n, no solo las RPC.
--
--   EL DEFECTO ERA EL ALCANCE DEL BLOQUEO, no la polÃ­tica:
--       el recurso que se limita es POR JUGADOR,
--       pero las funciones de despacho sÃ³lohacÃ­an
--           SELECT ... FROM planets WHERE id = p_origin_planet_id FOR UPDATE
--       es decir, bloqueaban el PLANETA DE ORIGEN.
--
--   Consecuencia: dos despachos concurrentes del MISMO jugador desde planetas
--   DISTINTOS no se serializan. Ambos cuentan los mismos slots libres, ambos pasan
--   el assert, y ambos insertan => N slots disponibles se convierten en N+1 flotas
--   activas. El tope se puede rebasar sin tocar nada del cliente.
--
-- POR QUÃ‰ NO ES UNA DECISIÃ“N DE PRODUCTO
--   No se cambia la fÃ³rmula, ni el tope, ni los estados que cuentan, ni cuÃ¡ndo se
--   libera. SÃ³lo se hace que un lÃ­mite YA decidido se cumpla tambiÃ©n bajo
--   concurrencia. Dark Matter / Officers / premium quedan FUERA a propÃ³sito: el
--   tope es 1 + computer_technology y no depende de ninguna economÃ­a premium.
--
-- POR QUÃ‰ ESTE ENLUGAR Y NO OTRO
--   assert_player_fleet_slot_available es el Ãºnico cuello de botella por el que
--   pasa toda inserciÃ³n en fleet_movements (el trigger y la IA). Serializar aquÃ­
--   protege todos los caminos de una vez. Se toma UN solo lock por transacciÃ³n, asÃ­
--   que no puede formarse un ciclo de deadlock por este lock. El orden respecto al
--   lock de planeta no cambia: primero planeta (en el despacho), despuÃ©s jugador.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.assert_player_fleet_slot_available(p_player_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
    v_max_slots integer;
    v_in_use integer;
    v_locked   uuid;
BEGIN
    IF p_player_id IS NULL THEN
        RAISE EXCEPTION 'FLEET_SLOT_PLAYER_REQUIRED';
    END IF;

    /* El limite es POR JUGADOR => el lock tambien. Antes solo se bloqueaba el
       planeta de origen en cada despacho, que no serializa despachos del mismo
       jugador desde planetas distintos. */
    SELECT pl.id INTO v_locked
      FROM public.players pl
     WHERE pl.id = p_player_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'FLEET_SLOT_PLAYER_NOT_FOUND: %', p_player_id;
    END IF;

    v_max_slots := public.calculate_player_max_fleet_slots(p_player_id);
    v_in_use := public.calculate_player_fleet_slots_in_use(p_player_id);

    IF v_in_use >= v_max_slots THEN
        RAISE EXCEPTION 'FLEET_SLOTS_FULL: %/%', v_in_use, v_max_slots;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.assert_player_fleet_slot_available(uuid) IS
  'Comprueba (y serializa por jugador) el limite de slots de flota: max = 1 + computer_technology. Bloquea la fila del jugador porque el recurso es por jugador, no por planeta. Sin este lock, dos despachos concurrentes desde planetas distintos pueden superar juntos el tope.';

COMMIT;