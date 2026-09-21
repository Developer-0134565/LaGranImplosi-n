-- ============================================================================
-- LOCK DOWN public.process_defense_queue_until  (forward-only)   [finding D-01]
-- ----------------------------------------------------------------------------
-- DEFECT (confirmed against LIVE on 2026-09-21):
--   public.process_defense_queue_until(p_planet_id uuid, p_until timestamptz)
--     SECURITY DEFINER, search_path = 'public', 'pg_temp'
--     ACL = { =X/postgres, postgres, service_role }     <- EXECUTE publico
--     body: loops the planet's defense_queue rows with status='BUILDING' AND
--           finishes_at <= p_until (a CALLER-SUPPLIED bound), UPSERTs
--           planet_defenses and marks the row COMPLETED.
--     -> there is NO ownership check and NO clamp to now(), so ANY client
--        (including anon, holding only the publishable key) could force-complete
--        ANY planet's defense construction instantly with a far-future p_until.
--
-- LIVE EVIDENCE (rolled back, 2026-09-21):
--   an authenticated client AND an anon client both executed the call without error,
--   and a defense_queue row scheduled to finish in 1 DAY became COMPLETED with the
--   planet_defenses row materialised -> build time bypassed.
--
-- WHY A REVOKE IS THE CORRECT MINIMAL FIX:
--   * its only LIVE consumers are the trusted engine resolvers resolve_attack_arrival
--     and resolve_espionage_arrival, driven by the heartbeat chain, which execute as
--     the owner;
--   * process_planet_tick_local uses the now()-bounded process_defense_queue(planet)
--     and is unaffected;
--   * the shipyard twin process_shipyard_queue_until is already restricted to
--     postgres/service_role, so this restores the intended symmetry;
--   * no signature, body, SECURITY DEFINER or search_path is touched: only the ACL.
-- ============================================================================

BEGIN;

REVOKE ALL ON FUNCTION public.process_defense_queue_until(uuid, timestamp with time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_defense_queue_until(uuid, timestamp with time zone) FROM anon;
REVOKE ALL ON FUNCTION public.process_defense_queue_until(uuid, timestamp with time zone) FROM authenticated;

DO $gate$
DECLARE
  v_sig text := 'public.process_defense_queue_until(uuid,timestamp with time zone)';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'process_defense_queue_until'
  ) THEN
    RAISE EXCEPTION 'D01_POSTCONDITION_FAILED: the function no longer exists';
  END IF;

  IF has_function_privilege('anon', v_sig, 'EXECUTE')
     OR has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'D01_POSTCONDITION_FAILED: a client role can still execute the processor';
  END IF;

  IF NOT has_function_privilege('service_role', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'D01_POSTCONDITION_FAILED: service_role lost EXECUTE on the processor';
  END IF;
END
$gate$;

COMMIT;
