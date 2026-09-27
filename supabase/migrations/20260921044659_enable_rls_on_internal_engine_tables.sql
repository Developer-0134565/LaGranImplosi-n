-- ============================================================================
-- ENABLE RLS on the two internal engine tables  (forward-only)  [finding M-04]
-- ----------------------------------------------------------------------------
-- LIVE state (2026-09-20):
--   public.universe_process_health       owner postgres, RLS DISABLED, 0 policies
--   public.combat_battle_participants    owner postgres, RLS DISABLED, 0 policies
--   grants for both: anon SELECT = false, authenticated SELECT = false,
--                    anon/authenticated INSERT/UPDATE/DELETE = false,
--                    service_role SELECT = true
--
-- WHY ENABLING RLS IS ZERO-RISK HERE (measured, not assumed):
--   * pg_roles: postgres.rolbypassrls = true, service_role.rolbypassrls = true,
--     anon.rolbypassrls = false, authenticated.rolbypassrls = false.
--     -> The only two roles that can reach these tables keep full access.
--   * anon and authenticated already hold no privileges on either table, so
--     enabling RLS changes nothing for them (they were already denied).
--   * Both tables are internal engine state: universe_process_health is written
--     by process_universe_heartbeat / process_universe_tick and holds per-universe
--     health counters; combat_battle_participants holds combat participant rows.
--     Neither holds player-facing data and neither has a client reader.
--
-- Deliberately NOT added: no policy is created. These tables have no client
-- consumer, so a policy would be an invented contract. Enabling RLS without
-- policies is the minimal correction: it removes the advisor finding and makes a
-- future accidental GRANT fail closed instead of fail open.
--
-- Idempotent: ENABLE ROW LEVEL SECURITY on an already-RLS table is a no-op.
-- ============================================================================

BEGIN;

ALTER TABLE public.universe_process_health ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.combat_battle_participants ENABLE ROW LEVEL SECURITY;

-- Postcondition: both tables must report relrowsecurity = true.
DO $gate$
DECLARE
  v_open integer;
BEGIN
  SELECT count(*) INTO v_open
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN ('universe_process_health', 'combat_battle_participants')
    AND NOT c.relrowsecurity;

  IF v_open > 0 THEN
    RAISE EXCEPTION 'M04_POSTCONDITION_FAILED: % table(s) still without RLS', v_open;
  END IF;
END
$gate$;

COMMIT;
