DO $$
DECLARE
  v_u uuid := '86900cbc-467d-4e23-85fa-7ba6302a57eb';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.universes WHERE id=v_u) THEN
    RAISE EXCEPTION 'test universe missing';
  END IF;
  -- Move only the TEST universe scheduler timestamps 48h into the past.
  UPDATE public.universe_clock
  SET next_tick_at = now() - interval '48 hours', last_tick_at = now() - interval '48 hours', is_processing=false
  WHERE universe_id=v_u;
  UPDATE public.universe_expansion_state
  SET next_galaxy_roll_at = now() - interval '48 hours'
  WHERE universe_id=v_u;
  UPDATE public.universe_population_state
  SET next_reconciliation_at = now() - interval '48 hours'
  WHERE universe_id=v_u;
  UPDATE public.universe_galaxies
  SET next_system_expansion_at = now() - interval '48 hours'
  WHERE universe_id=v_u;
END $$;