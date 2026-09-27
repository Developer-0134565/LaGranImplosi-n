-- ============================================================================
-- HARDEN the building/combat ANALYSIS helper surface  (forward-only)  [finding C-02]
-- ----------------------------------------------------------------------------
-- DEFECT (confirmed against LIVE on 2026-09-20):
--   public.generate_building_sequences(p_depth integer)
--     non-SECURITY DEFINER
--     ACL = { =X/postgres, postgres, anon, authenticated, service_role }
--     WITH RECURSIVE ... CROSS JOIN building_definitions b
--       WHERE s.depth < p_depth AND b.id IN (4 building ids)
--   -> 4-way branching to an UNBOUNDED p_depth. p_depth = 20 yields 4^20 ~ 1.1e12
--      candidate rows before the final filter. Reachable by anyone holding only
--      the publishable key, against the same database that runs the 1-second
--      fleet worker and the 1-minute universe heartbeat.
--
-- EVIDENCE THAT A REVOKE IS THE CORRECT MINIMAL FIX (no redesign, no invented bound):
--   * Repo consumers (src/, worker/, scripts/, supabase/tests/, migrations): 0.
--     The only non-doc references are the generated types.
--   * LIVE consumers: exactly rank_building_sequences,
--     rank_building_sequences_horizons and rank_building_sequences_snapshot —
--     all inside this same family, all non-SECURITY DEFINER, all revoked here.
--   * No SECURITY DEFINER function calls this family (verified across every
--     public + private body), so no engine path can be broken by the revoke.
--   * The 21 analysis VIEWs execute as their owner (postgres, BYPASSRLS) and are
--     unaffected by function ACLs.
--   * No defensive depth bound is invented: the intended caller is undocumented,
--     so bounding it would be a guess. Restricting access is reversible by a
--     later forward migration.
--
-- NOT included on purpose: public.calculate_sequence_crossover. Its cost is
-- caller-bounded (it receives the sequences as text[]), so revoking it would
-- change a contract with no demonstrated security benefit.
--
-- IMPLEMENTATION NOTE: the revoke is driven by the catalog instead of by
-- hand-written signatures, so the migration cannot fail on a signature typo and
-- is naturally idempotent (already-revoked privileges are a no-op).
-- ============================================================================

BEGIN;

DO $patch$
DECLARE
  v_fn        text;
  v_signature text;
  v_functions text[] := ARRAY[
    'generate_building_sequences',
    'rank_building_sequences',
    'rank_building_sequences_horizons',
    'rank_building_sequences_snapshot',
    'simulate_building_chain',
    'simulate_building_chain_2',
    'simulate_building_chain_3',
    'simulate_building_chain_snapshot',
    'simulate_building_completion',
    'simulate_building_step',
    'simulate_building_step_snapshot',
    'simulate_defender_losses',
    'evaluate_building_chain',
    'evaluate_building_chain_horizon',
    'evaluate_building_chain_snapshot',
    'snapshot_combat_round',
    'calculate_action_payback'
  ];
  v_touched   integer := 0;
  v_still_open integer;
BEGIN
  FOR v_signature IN
    SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname = ANY (v_functions)
  LOOP
    EXECUTE format('revoke all on function %s from public', v_signature);
    EXECUTE format('revoke all on function %s from anon', v_signature);
    EXECUTE format('revoke all on function %s from authenticated', v_signature);
    v_touched := v_touched + 1;
  END LOOP;

  IF v_touched = 0 THEN
    RAISE EXCEPTION 'C02_PRECONDITION_FAILED: none of the analysis functions were found in public';
  END IF;

  -- Postcondition: no anon/authenticated EXECUTE and no PUBLIC EXECUTE left.
  SELECT count(*) INTO v_still_open
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND p.proname = ANY (v_functions)
    AND (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
    );

  IF v_still_open > 0 THEN
    RAISE EXCEPTION 'C02_POSTCONDITION_FAILED: % function(s) still executable by anon/authenticated', v_still_open;
  END IF;

  RAISE NOTICE 'C02 applied: % function signature(s) hardened', v_touched;
END
$patch$;

COMMIT;
