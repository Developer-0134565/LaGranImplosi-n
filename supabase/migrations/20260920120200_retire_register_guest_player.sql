-- ============================================================================
-- RETIRE public.register_guest_player  (forward-only)
-- ----------------------------------------------------------------------------
-- The guest onboarding RPC required an ANONYMOUS JWT and created
-- is_guest = true players. The product model is email/password only and its
-- replacement is public.provision_player(text, text).
--
-- Preconditions verified in the repository before this migration exists:
--   * src/ has 0 callers of register_guest_player (grep: only comments/types);
--   * src/main.tsx no longer creates anonymous sessions;
--   * the provisioning RPC covers player + homeworld + resources + research.
--
-- NOT removed here (pending product decision, documented):
--   * public.early_tester_registrations  (only writer was this RPC)
--   * public.player_achievements         (only writer was this RPC)
-- Their retention/retirement is a separate decision; dropping the RPC only
-- stops new rows from being written.
--
-- Operational order: deploy the frontend that calls provision_player() BEFORE
-- applying this migration.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.register_guest_player(text, text, text) FROM authenticated;

DROP FUNCTION IF EXISTS public.register_guest_player(text, text, text);

COMMIT;
