-- ============================================================================
-- LIVE GUEST OWNERSHIP RECONCILIATION
-- ----------------------------------------------------------------------------
-- Applies the guest-hardening intent of the historical
-- 20260920120800_remove_guest_ownership_bypasses.sql against the actual LIVE
-- function shapes observed on 2026-09-28.
--
-- The historical migration is intentionally not replayed: LIVE had drifted
-- from its documented shape and its original regex precondition fails on
-- start_colonize_fleet. This migration is the forward-only corrective form.
-- ============================================================================

BEGIN;

DO $patch$
DECLARE v_sig text; v_sql text; v_new text;
BEGIN
  FOR v_sig IN
    SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prokind='f'
      AND p.proname IN ('start_fleet','start_fleet_mixed','start_colonize_fleet')
  LOOP
    v_sql:=pg_get_functiondef(v_sig::regprocedure);
    IF v_sql !~* 'is_guest' THEN CONTINUE; END IF;
    v_new:=replace(v_sql,
      '(coalesce(pl.is_guest,false) or public.is_ai_actor_target(pl.id))',
      'public.is_ai_actor_target(pl.id)');
    IF v_new=v_sql THEN
      RAISE EXCEPTION 'FLEET_GUEST_PATCH_NOOP: %',v_sig;
    END IF;
    IF v_new~*'is_guest' THEN
      RAISE EXCEPTION 'FLEET_POSTCONDITION_FAILED: %',v_sig;
    END IF;
    EXECUTE v_new;
  END LOOP;
END
$patch$;

DO $patch$
DECLARE v_sig text; v_sql text; v_new text;
BEGIN
  FOR v_sig IN
    SELECT p.oid::regprocedure::text
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prokind='f'
      AND p.proname IN ('start_lifeform_building','start_lifeform_research')
  LOOP
    v_sql:=pg_get_functiondef(v_sig::regprocedure);
    IF v_sql !~* 'is_guest' THEN CONTINUE; END IF;
    v_new:=regexp_replace(
      v_sql,
      'IF v_auth_user IS NULL AND NOT EXISTS \(SELECT 1 FROM public\.players WHERE id=v_player AND coalesce\(is_guest,false\)=true\) THEN',
      'IF v_auth_user IS NULL THEN',
      'i'
    );
    IF v_new=v_sql THEN
      RAISE EXCEPTION 'LIFEFORM_GUEST_PATCH_NOOP: %',v_sig;
    END IF;
    IF v_new~*'is_guest' THEN
      RAISE EXCEPTION 'LIFEFORM_POSTCONDITION_FAILED: %',v_sig;
    END IF;
    EXECUTE v_new;
  END LOOP;
END
$patch$;

DO $patch$
DECLARE
  v_sql text:=pg_get_functiondef('public.sync_current_planet_resources(uuid,uuid,timestamptz)'::regprocedure);
  v_new text;
BEGIN
  IF v_sql~*'is_guest' THEN
    v_new:=regexp_replace(v_sql,'\s*v_is_guest boolean;','',1,0,'i');
    v_new:=regexp_replace(
      v_new,
      '\s*select coalesce\(pl\.is_guest, false\)\s*into v_is_guest\s*from public\.players pl\s*where pl\.id = p_player_id;\s*if not found then\s*raise exception ''PLAYER_NOT_FOUND'';\s*end if;',
      '',
      1,0,'is'
    );
    IF v_new=v_sql OR v_new~*'is_guest' THEN
      RAISE EXCEPTION 'SYNC_PATCH_FAILED';
    END IF;
    EXECUTE v_new;
  END IF;
END
$patch$;

DO $patch$
DECLARE
  v_sql text:=pg_get_functiondef('public.enforce_player_write_access()'::regprocedure);
  v_new text;
BEGIN
  IF v_sql~*'is_guest' THEN
    v_new:=regexp_replace(v_sql,'\s*v_is_guest boolean;','',1,0,'i');
    v_new:=regexp_replace(
      v_new,
      'select pl\.is_guest, pl\.user_id\s*into v_is_guest, v_user_id',
      'select pl.user_id into v_user_id',
      'i'
    );
    v_new:=regexp_replace(
      v_new,
      'elsif coalesce\(v_is_guest, false\) is not true then\s*raise exception ''AUTHENTICATION_REQUIRED'';\s*end if;',
      'else raise exception ''AUTHENTICATION_REQUIRED''; end if;',
      'i'
    );
    IF v_new=v_sql OR v_new~*'is_guest' THEN
      RAISE EXCEPTION 'WRITE_PATCH_FAILED';
    END IF;
    IF v_new!~*'PLAYER_NOT_OWNED_BY_AUTH_USER' THEN
      RAISE EXCEPTION 'WRITE_OWNERSHIP_GUARD_LOST';
    END IF;
    EXECUTE v_new;
  END IF;
END
$patch$;

DO $gate$
DECLARE v_left integer;
BEGIN
  SELECT count(*) INTO v_left
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.prokind='f'
    AND pg_get_functiondef(p.oid)~*'is_guest'
    AND p.proname NOT IN ('register_guest_player','reconcile_universe_ai_population');
  IF v_left>0 THEN
    RAISE EXCEPTION 'FINAL_GATE_FAILED: %',v_left;
  END IF;
END
$gate$;

COMMIT;
