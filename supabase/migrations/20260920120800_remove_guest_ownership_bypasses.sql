-- ============================================================================
-- REMOVE GUEST OWNERSHIP BYPASSES  (forward-only, self-verifying patcher)
-- ----------------------------------------------------------------------------
-- Findings closed at the repo level: H-01, H-02, H-03.
--
-- Supersedes 20260920120300_remove_guest_authorization_branches.sql, which
-- CANNOT execute against LIVE: its patch-1 and patch-2 preconditions require the
-- literal fragment `v_auth_user IS NULL AND NOT EXISTS`, but the real LIVE shape
-- is `IF v_auth_user IS NOT NULL THEN ... ELSIF NOT EXISTS(...)`. That migration
-- raises PRECONDITION_FAILED and rolls back. It is preserved as a `.superseded`
-- artifact, never deleted.
--
-- REAL LIVE SHAPES (verified 2026-09-20 via pg_get_functiondef):
--
--   A) start_fleet / start_fleet_mixed / start_colonize_fleet
--        IF <auth> IS NOT NULL THEN
--          IF NOT EXISTS(... pl.user_id = <auth>) THEN raise 'Player does not
--             belong to authenticated user'; END IF;
--        ELSIF NOT EXISTS(... coalesce(pl.is_guest,false))
--        THEN raise 'Authentication required'; END IF;
--      -> the ELSIF branch is the bypass: it authorises a SESSION-LESS caller
--         whenever the target player is flagged is_guest.
--
--   B) start_lifeform_building / start_lifeform_research  (patched in part 2)
--        IF v_auth_user IS NOT NULL AND NOT EXISTS(... user_id=v_auth_user)
--        THEN raise 'Player does not belong to authenticated user'; END IF;
--        IF v_auth_user IS NULL AND NOT EXISTS(... coalesce(is_guest,false)=true)
--        THEN raise 'Authentication required'; END IF;
--      -> ownership for authenticated callers is a SEPARATE first guard and is
--         preserved untouched; only the second (guest) guard is replaced.
--
-- GUARANTEES
--   * idempotent     — a target whose body no longer mentions is_guest is skipped;
--   * self-verifying — a target that still mentions is_guest with an unexpected
--                      shape raises, so the migration rolls back instead of
--                      silently leaving a bypass alive;
--   * preserves SECURITY DEFINER and search_path — the patched DDL is the
--     verbatim pg_get_functiondef output, re-executed;
--   * changes no other contract, formula or validation;
--   * keeps the authenticated-ownership branches intact, so:
--       authenticated owner -> PASS · other authenticated user -> DENY ·
--       session-less caller -> DENY.
--
-- POST-DEPLOYMENT VERIFICATION (see docs/audits/LIVE_INTEGRITY_RECONCILIATION_2026-09-20.md):
--   select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--   where n.nspname='public' and pg_get_functiondef(p.oid) ~* 'is_guest'
--     and p.proname not in ('register_guest_player','reconcile_universe_ai_population');
--   -- must return 0 rows
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A) fleet family: drop the ELSIF guest branch, keep the ownership branch
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_sig     text;
  v_sql     text;
  v_new     text;
  v_touched integer := 0;
  v_left    integer;
  v_re      text := $re$ELSIF\s+NOT\s+EXISTS\s*\(\s*select\s+1\s+from\s+public\.players\s+pl\s+where\s+pl\.id\s*=\s*p_player_id\s+and\s+coalesce\s*\(\s*pl\.is_guest\s*,\s*false\s*\)\s*\)\s*THEN\s+raise\s+exception\s+'Authentication required';\s*END\s+IF;$re$;
  v_rp      text := $rp$END IF;
  IF auth.uid() IS NULL THEN raise exception 'Authentication required'; END IF;$rp$;
BEGIN
  FOR v_sig IN
    SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname IN ('start_fleet', 'start_fleet_mixed', 'start_colonize_fleet')
  LOOP
    v_sql := pg_get_functiondef(v_sig::regprocedure);

    IF v_sql !~* 'is_guest' THEN
      CONTINUE;                                   -- already hardened: idempotent
    END IF;

    IF v_sql !~* 'ELSIF\s+NOT\s+EXISTS' THEN
      RAISE EXCEPTION 'A_SHAPE_UNEXPECTED: % has an is_guest reference but no ELSIF guest guard', v_sig;
    END IF;

    v_new := regexp_replace(v_sql, v_re, v_rp, 'i');

    IF v_new = v_sql THEN
      RAISE EXCEPTION 'A_PATCH_NOOP: % matched the precondition but the replacement changed nothing', v_sig;
    END IF;

    IF v_new ~* 'is_guest' THEN
      RAISE EXCEPTION 'A_POSTCONDITION_FAILED: % still references is_guest', v_sig;
    END IF;

    EXECUTE v_new;
    v_touched := v_touched + 1;
  END LOOP;

  IF v_touched = 0 THEN
    SELECT count(*) INTO v_left
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('start_fleet', 'start_fleet_mixed', 'start_colonize_fleet')
      AND pg_get_functiondef(p.oid) ~* 'is_guest';
    IF v_left > 0 THEN
      RAISE EXCEPTION 'A_UNRESOLVED: % fleet function(s) still reference is_guest', v_left;
    END IF;
  END IF;

  RAISE NOTICE 'A applied: % fleet function(s) hardened', v_touched;
END
$patch$;

-- ---------------------------------------------------------------------------
-- B) lifeform family: replace ONLY the second (guest) guard.
--    The first guard (`v_auth_user IS NOT NULL AND NOT EXISTS(... user_id=v_auth_user)`)
--    is the authenticated-ownership check and is left byte-identical.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_sig text;
  v_sql text;
  v_new text;
  v_touched integer := 0;
  v_re  text := $re$IF\s+v_auth_user\s+IS\s+NULL\s+AND\s+NOT\s+EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+public\.players\s+WHERE\s+id\s*=\s*v_player\s+AND\s+coalesce\s*\(\s*is_guest\s*,\s*false\s*\)\s*=\s*true\s*\)\s*THEN\s+RAISE\s+EXCEPTION\s+'Authentication required';\s*END\s+IF;$re$;
  v_rp  text := $rp$IF v_auth_user IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;$rp$;
BEGIN
  FOR v_sig IN
    SELECT p.oid::regprocedure::text
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND p.proname IN ('start_lifeform_building', 'start_lifeform_research')
  LOOP
    v_sql := pg_get_functiondef(v_sig::regprocedure);
    IF v_sql !~* 'is_guest' THEN CONTINUE; END IF;
    IF v_sql !~* 'v_auth_user\s+IS\s+NULL\s+AND\s+NOT\s+EXISTS' THEN
      RAISE EXCEPTION 'B_SHAPE_UNEXPECTED: % has an is_guest reference but no NULL-auth guest guard', v_sig;
    END IF;
    v_new := regexp_replace(v_sql, v_re, v_rp, 'i');
    IF v_new = v_sql THEN
      RAISE EXCEPTION 'B_PATCH_NOOP: % replacement changed nothing', v_sig;
    END IF;
    IF v_new ~* 'is_guest' THEN
      RAISE EXCEPTION 'B_POSTCONDITION_FAILED: % still references is_guest', v_sig;
    END IF;
    IF v_new !~* 'v_auth_user\s+IS\s+NOT\s+NULL\s+AND\s+NOT\s+EXISTS' THEN
      RAISE EXCEPTION 'B_OWNERSHIP_LOST: % lost its authenticated-ownership guard', v_sig;
    END IF;
    EXECUTE v_new;
    v_touched := v_touched + 1;
  END LOOP;
  RAISE NOTICE 'B applied: % lifeform function(s) hardened', v_touched;
END
$patch$;

-- ---------------------------------------------------------------------------
-- C) sync_current_planet_resources: remove the dead v_is_guest residue.
--    Behaviour is unchanged: a missing player still fails, via the following
--    PLAYER_ACCESS_DENIED check (player_id + user_id = auth.uid()).
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_sql text := pg_get_functiondef('public.sync_current_planet_resources(uuid,uuid,timestamptz)'::regprocedure);
  v_new text;
BEGIN
  IF v_sql !~* 'is_guest' THEN
    RAISE NOTICE 'C skipped: sync_current_planet_resources already clean';
  ELSE
    IF v_sql !~* 'v_is_guest' THEN
      RAISE EXCEPTION 'C_SHAPE_UNEXPECTED: sync_current_planet_resources has an is_guest reference that is not v_is_guest';
    END IF;
    v_new := regexp_replace(v_sql, $re$v_is_guest\s+boolean;\s*$re$, '', 'gi');
    v_new := regexp_replace(
      v_new,
      $re$select\s+coalesce\(\s*pl\.is_guest\s*,\s*false\s*\)\s+into\s+v_is_guest\s+from\s+public\.players\s+pl\s+where\s+pl\.id\s*=\s*p_player_id;\s*if\s+not\s+found\s+then\s+raise\s+exception\s+'PLAYER_NOT_FOUND';\s*end\s+if;\s*$re$,
      '', 'i'
    );
    IF v_new = v_sql THEN
      RAISE EXCEPTION 'C_PATCH_NOOP: sync_current_planet_resources replacement changed nothing';
    END IF;
    IF v_new ~* 'is_guest' THEN
      RAISE EXCEPTION 'C_POSTCONDITION_FAILED: sync_current_planet_resources still references is_guest';
    END IF;
    EXECUTE v_new;
    RAISE NOTICE 'C applied: sync_current_planet_resources residue removed';
  END IF;
END
$patch$;

-- ---------------------------------------------------------------------------
-- D) enforce_player_write_access: the NULL-auth + is_guest fallback stops being
--    a valid authorisation path. The ownership comparison against
--    players.user_id is preserved exactly.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  v_sql text := pg_get_functiondef('public.enforce_player_write_access()'::regprocedure);
  v_new text;
  v_re1 text := $re$select\s+pl\.is_guest\s*,\s*pl\.user_id\s+into\s+v_is_guest\s*,\s*v_user_id\s+from\s+public\.players\s+pl\s+where\s+pl\.id\s*=\s*v_player_id;$re$;
  v_rp1 text := 'select pl.user_id into v_user_id from public.players pl where pl.id = v_player_id;';
  v_re2 text := $re$if\s+v_user_id\s+is\s+null\s+then\s+if\s+coalesce\(\s*v_is_guest\s*,\s*false\s*\)\s+is\s+not\s+true\s+then\s+raise\s+exception\s+'AUTHENTICATION_REQUIRED';\s*end\s+if;\s*elsif$re$;
  v_rp2 text := 'if v_user_id is null then raise exception ''AUTHENTICATION_REQUIRED''; elsif';
BEGIN
  IF v_sql !~* 'is_guest' THEN
    RAISE NOTICE 'D skipped: enforce_player_write_access already clean';
  ELSE
    IF v_sql !~* 'v_is_guest' THEN
      RAISE EXCEPTION 'D_SHAPE_UNEXPECTED: enforce_player_write_access has an is_guest reference that is not v_is_guest';
    END IF;

    v_new := regexp_replace(v_sql, v_re1, v_rp1, 'i');
    v_new := regexp_replace(v_new, v_re2, v_rp2, 'i');
    v_new := regexp_replace(v_new, $re$v_is_guest\s+boolean;\s*$re$, '', 'gi');

    IF v_new = v_sql THEN
      RAISE EXCEPTION 'D_PATCH_NOOP: enforce_player_write_access replacement changed nothing';
    END IF;
    IF v_new ~* 'is_guest' THEN
      RAISE EXCEPTION 'D_POSTCONDITION_FAILED: enforce_player_write_access still references is_guest';
    END IF;
    IF v_new !~* 'PLAYER_NOT_OWNED_BY_AUTH_USER' THEN
      RAISE EXCEPTION 'D_OWNERSHIP_LOST: enforce_player_write_access lost its ownership comparison';
    END IF;
    IF v_new !~* 'PLAYER_ACCESS_DENIED' THEN
      RAISE EXCEPTION 'D_ACCESS_CHECK_LOST: enforce_player_write_access lost its null-player guard';
    END IF;

    EXECUTE v_new;
    RAISE NOTICE 'D applied: enforce_player_write_access no longer accepts a session-less guest write';
  END IF;
END
$patch$;

-- ---------------------------------------------------------------------------
-- Final gate: after this migration, only the two objects that are REMOVED in a
-- later, separately-ordered step may still mention is_guest.
-- ---------------------------------------------------------------------------
DO $gate$
DECLARE
  v_left integer;
BEGIN
  SELECT count(*) INTO v_left
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f'
    AND pg_get_functiondef(p.oid) ~* 'is_guest'
    AND p.proname NOT IN ('register_guest_player', 'reconcile_universe_ai_population');

  IF v_left > 0 THEN
    RAISE EXCEPTION 'FINAL_GATE_FAILED: % function(s) still carry an is_guest bypass', v_left;
  END IF;
END
$gate$;

COMMIT;


