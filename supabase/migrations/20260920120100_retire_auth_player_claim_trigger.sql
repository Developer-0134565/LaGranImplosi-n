-- ============================================================================
-- RETIRE THE AUTH-USER PLAYER CLAIM TRIGGER  (forward-only)
-- ----------------------------------------------------------------------------
-- Historical behaviour (20260913012344): AFTER INSERT ON auth.users →
-- private.handle_new_auth_user() claimed the OLDEST players row with
-- user_id IS NULL (which includes AI empires, inserted with user_id = NULL)
-- or created a bare player row with no homeworld/resources/research.
--
-- Target model: an authenticated user NEVER receives/claims an existing player.
-- Their empire is created explicitly by public.provision_player() for their own
-- auth.uid(). Therefore the trigger and its function are removed.
--
-- No AI row, no DevPlayer row and no legacy row is touched or migrated.
-- The provisioning RPC is the single creation path (idempotent).
--
-- NOTE (operational order): apply this AFTER the frontend build that calls
-- provision_player() has been deployed, so a new sign-up always has a way to
-- provision its own empire.
-- ============================================================================

BEGIN;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

-- The function only existed to serve that trigger. Dropping it guarantees that
-- no future code path can re-enable silent player adoption by mistake.
DROP FUNCTION IF EXISTS private.handle_new_auth_user();

COMMIT;
