-- ============================================================================
-- OPEN: restore authenticated EXECUTE on public.provision_player
-- ----------------------------------------------------------------------------
-- WHY THIS FILE EXISTS (evidence, not assumption)
--
--   Repo's own intent, declared twice and applied to LIVE:
--     20260921073405  grant execute ... to authenticated   [2-arg signature]
--     20260926296000  grant execute ... to authenticated   [2-arg signature]
--
--   Current LIVE signature (measured):
--     provision_player(p_username text, p_country_code text,
--                      p_planet_name text, p_avatar_id text)
--     owner postgres - SECURITY DEFINER - search_path ''
--     ACL = {postgres, service_role}      <-- authenticated MISSING
--
--   Root cause: the two GRANTs above target the OLD 2-argument overload
--   provision_player(text, text). That overload no longer exists; onboarding
--   work replaced it with the 4-argument version, whose CREATE OR REPLACE
--   carries no GRANT of its own. The grant was orphaned onto a signature that
--   was dropped, so the privilege silently disappeared with it.
--
--   Note: CREATE OR REPLACE cannot change an argument list, so adding
--   p_planet_name / p_avatar_id produced a NEW overload rather than replacing
--   the old one. The old one was dropped out-of-band, taking its ACL with it.
--
--   This migration is NOT an assertion and NOT a no-op: it restores a
--   privilege the repository already declares in two earlier migrations.
--
-- PROVEN FAILURE (empirical, not inferred)
--   Caller  : src/lib/identity.ts -> supabase.rpc('provision_player', {...})
--             wired from src/App.tsx handleOnboarding() -> <OnboardingPanel/>
--   Session : real Supabase Auth user, JWT role = authenticated
--   Result  : HTTP 403  code 42501
--             "permission denied for function provision_player"
--   The privilege check runs before the function body, so nothing was created.
--   Frontend path: error is rethrown and rendered as the onboarding error,
--   so EVERY new account without a player is blocked from provisioning.
--
--   The existing regression battery already detects this:
--   supabase/tests/wrong_client_invoker_helpers.sql test 9 asserts every UI
--   contract keeps authenticated EXECUTE. It currently measures 52 contracts
--   / 51 with the grant -> FAIL. After this migration: 52 / 52 -> PASS.
--
-- WHY GRANTING TO authenticated IS SAFE (not a privilege widening)
--
--   The function was designed for exactly this caller. Identity is NEVER a
--   parameter:
--     * v_user_id := auth.uid()          -- derived from the verified JWT
--     * AUTHENTICATION_REQUIRED if null  -- no anonymous path
--     * SECURITY DEFINER + search_path '' + owner postgres
--
--   Therefore an authenticated caller CANNOT:
--     * provision a player for another identity (no client-supplied user id);
--     * create or claim a foreign planet (planet.player_id comes from
--       v_player_id, which comes from auth.uid());
--     * pick the universe (taken from the single is_active universe);
--     * escalate, because everything it creates is already bound to itself.
--
--   Abuse vectors checked and closed by the existing body:
--     * replay / double provisioning -> reuse-first SELECT on
--       players.user_id = v_user_id returns the existing empire and exits;
--     * concurrency -> pg_advisory_xact_lock('lgi_player_provisioning_v1');
--     * username injection -> length 3-24, charset ^[[:alnum:] _.-]+$,
--       reserved name 'devplayer' rejected;
--     * input normalisation -> btrim + regex_replace on country code.
--
--   A service_role route would be strictly WORSE: it would require passing the
--   user id as a parameter, turning client-supplied identity into authority.
--   Direct authenticated EXECUTE is the correct shape.
--
-- SCOPE
--   Exactly one GRANT on exactly one function. No function body change, no
--   SECURITY DEFINER/INVOKER change, no RLS, no tables, no data, no other
--   grants. Forward-only, idempotent (re-running is a no-op).
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.provision_player(text, text, text, text)
  TO authenticated;

-- Post-condition, same shape as the repo's other ACL migrations: assert the
-- restored grant and assert the hardening that must NOT move.
DO $verify$
DECLARE
  v_fn oid;
BEGIN
  SELECT p.oid INTO v_fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'provision_player'
     AND pg_get_function_identity_arguments(p.oid) =
         'p_username text, p_country_code text, p_planet_name text, p_avatar_id text';

  IF v_fn IS NULL THEN
    RAISE EXCEPTION 'PROVISION_PLAYER_ACL: 4-argument overload not found';
  END IF;

  IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROVISION_PLAYER_ACL: authenticated still has no EXECUTE';
  END IF;

  IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROVISION_PLAYER_ACL: anon must not be executable';
  END IF;

  IF has_function_privilege('public', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROVISION_PLAYER_ACL: PUBLIC must not be executable';
  END IF;

  IF NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROVISION_PLAYER_ACL: service_role lost EXECUTE';
  END IF;

  RAISE NOTICE 'PROVISION_PLAYER_ACL: authenticated restored; anon/PUBLIC still closed';
END;
$verify$;