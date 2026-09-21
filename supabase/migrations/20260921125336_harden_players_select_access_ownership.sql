-- ============================================================================
-- HARDEN public.players SELECT policy  (forward-only)   [P0 follow-up]
-- ----------------------------------------------------------------------------
-- DEFECT (confirmed against LIVE on 2026-09-21):
--   public.players_select_access used FOUR branches, two of which keyed identity on
--   hardcoded data instead of auth.uid():
--     (id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'::uuid)   <- hardcoded DEV player UUID
--     OR (player_type = 'AI')
--     OR ((is_guest = true) AND (username <> 'DevPlayer') AND (user_id IS NOT NULL))
--                                                           <- dead branch + hardcoded username
--     OR (user_id = (select auth.uid()))
--   Measured BEFORE: anon and a stranger authenticated session both read the DevPlayer row
--   (devplayer_row_visible = 1) purely through the hardcoded UUID branch.
--
-- WHY THE is_guest BRANCH IS REMOVED (evidence, not a sweep):
--   * public.players holds 0 rows with is_guest = true (378 rows, all false);
--   * no surviving function can write is_guest = true: register_guest_player is DROPPED
--     and reconcile_universe_ai_population only writes is_guest = false;
--   * therefore the branch matches no row now and no new row can arise.
--   It also carried the literal 'DevPlayer' username, i.e. a second hardcoded identity.
--
-- FIX: keep the intentional AI-gallery read (documented as required by the galaxy map for
--   owner names) and rebase ownership exclusively on auth.uid() -> players.user_id.
--   No hardcoded player UUID, no hardcoded username, no is_guest branch.
-- ============================================================================

DROP POLICY IF EXISTS players_select_access ON public.players;
CREATE POLICY players_select_access ON public.players
  FOR SELECT TO anon, authenticated
  USING (
    (player_type = 'AI'::text)
    OR (user_id = (select auth.uid()))
  );

-- Postcondition: the policy must be ownership-based and free of hardcoded identity.
DO $gate$
DECLARE
  v_bad integer;
BEGIN
  SELECT count(*) INTO v_bad
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'players'
    AND policyname = 'players_select_access'
    AND (
      coalesce(qual, '') ILIKE '%aa1deb2d%'
      OR coalesce(qual, '') ILIKE '%is_guest%'
      OR coalesce(qual, '') ILIKE '%DevPlayer%'
    );

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'PLAYERS_SELECT_ACCESS_POSTCONDITION_FAILED: the policy still references a hardcoded identity or is_guest';
  END IF;

  SELECT count(*) INTO v_bad
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'players'
    AND policyname = 'players_select_access'
    AND coalesce(qual, '') NOT ILIKE '%auth.uid()%';

  IF v_bad > 0 THEN
    RAISE EXCEPTION 'PLAYERS_SELECT_ACCESS_POSTCONDITION_FAILED: the policy is not ownership-based';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'players' AND c.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'PLAYERS_SELECT_ACCESS_POSTCONDITION_FAILED: RLS is no longer enabled on public.players';
  END IF;
END
$gate$;
