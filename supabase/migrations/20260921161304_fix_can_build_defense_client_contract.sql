-- ============================================================================
-- FIX public.can_build_defense FOR THE REAL CLIENT  (forward-only)   [finding D-02]
-- ----------------------------------------------------------------------------
-- DEFECT (confirmed against LIVE on 2026-09-21):
--   public.can_build_defense(uuid,uuid,text,bigint) is the Defense availability
--   contract consumed by src/App.tsx (view 'defense'), but it was declared
--   SECURITY INVOKER while depending on two objects the client role cannot read:
--     * check_defense_requirements reads public.defense_prerequisites, which carries
--       no anon/authenticated SELECT grant  -> "permission denied for table defense_prerequisites"
--     * calculate_defense_build_time reads public.universes, which has no client
--       SELECT grant                        -> "permission denied for table universes"
--   Executed as the real authenticated role the function therefore RAISED, the UI threw,
--   and the Defense view fell back to local base costs with no prerequisites and no
--   availability gating (only start_defense still enforced everything server-side).
--
-- FIX: make the contract SECURITY DEFINER (the same posture can_start_research uses) and
--   bind it to the caller with an explicit ownership gate, so becoming DEFINER cannot turn
--   it into a foreign-data oracle: the planet's resources are only projected for a player
--   that belongs to auth.uid(). A session-less caller is rejected with the canonical
--   reason code instead of being able to probe any planet.
--   Every other branch (quantity, planet ownership, requirements, cost, resources,
--   shield-dome uniqueness, build time) is preserved verbatim, and so are the reason
--   strings, so the existing frontend contract is unchanged for a legitimate owner.
--   EXECUTE is tightened from PUBLIC to authenticated, matching the Research/Shipyard
--   availability contracts.
-- ============================================================================

create or replace function public.can_build_defense(
  p_player_id uuid,
  p_planet_id uuid,
  p_defense_id text,
  p_quantity bigint default 1
)
 returns table(allowed boolean, reason text, defense_id text, quantity bigint, metal_cost numeric, crystal_cost numeric, deuterium_cost numeric, build_time_seconds numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_reason text;
  v_metal numeric;
  v_crystal numeric;
  v_deuterium numeric;
  v_metal_available numeric;
  v_crystal_available numeric;
  v_deuterium_available numeric;
  v_time numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN QUERY SELECT false,'AUTHENTICATION_REQUIRED',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.players pl
    WHERE pl.id = p_player_id AND pl.user_id = auth.uid()
  ) THEN
    RETURN QUERY SELECT false,'PLAYER_NOT_OWNED',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  IF p_quantity <= 0 THEN
    RETURN QUERY SELECT false,'Quantity must be greater than 0',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.planets p
    WHERE p.id=p_planet_id AND p.player_id=p_player_id AND NOT p.is_destroyed
  ) THEN
    RETURN QUERY SELECT false,'Planet does not belong to player',p_defense_id,p_quantity,0::numeric,0::numeric,0::numeric,0::numeric;
    RETURN;
  END IF;

  SELECT r.reason INTO v_reason
  FROM public.check_defense_requirements(p_planet_id,p_defense_id) r
  WHERE NOT r.allowed LIMIT 1;

  SELECT c.metal,c.crystal,c.deuterium
  INTO v_metal,v_crystal,v_deuterium
  FROM public.calculate_defense_cost(p_defense_id,p_quantity) c;

  IF v_reason IS NOT NULL THEN
    RETURN QUERY SELECT false,v_reason,p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  SELECT pr.metal,pr.crystal,pr.deuterium
  INTO v_metal_available,v_crystal_available,v_deuterium_available
  FROM public.get_current_planet_resources(p_planet_id) pr;

  IF v_metal_available < v_metal THEN
    RETURN QUERY SELECT false,'Not enough metal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;
  IF v_crystal_available < v_crystal THEN
    RETURN QUERY SELECT false,'Not enough crystal',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;
  IF v_deuterium_available < v_deuterium THEN
    RETURN QUERY SELECT false,'Not enough deuterium',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  IF p_defense_id IN ('small_shield_dome','large_shield_dome') AND (
    EXISTS (
      SELECT 1 FROM public.planet_defenses pd
      WHERE pd.planet_id=p_planet_id AND pd.defense_id=p_defense_id AND pd.quantity > 0
    )
    OR EXISTS (
      SELECT 1 FROM public.defense_queue dq
      WHERE dq.planet_id=p_planet_id AND dq.defense_id=p_defense_id AND dq.status='BUILDING'
    )
  ) THEN
    RETURN QUERY SELECT false,'Shield dome already exists or is queued',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,0::numeric;
    RETURN;
  END IF;

  v_time := public.calculate_defense_build_time(p_planet_id,p_defense_id);
  RETURN QUERY SELECT true,'OK',p_defense_id,p_quantity,v_metal,v_crystal,v_deuterium,v_time;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_build_defense(uuid, uuid, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_build_defense(uuid, uuid, text, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.can_build_defense(uuid, uuid, text, bigint) TO authenticated;

DO $gate$
DECLARE
  v_sig text := 'public.can_build_defense(uuid,uuid,text,bigint)';
  v_sec boolean;
  v_body text;
BEGIN
  SELECT p.prosecdef INTO v_sec
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'can_build_defense';

  IF v_sec IS NOT TRUE THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: can_build_defense is not SECURITY DEFINER';
  END IF;

  IF NOT has_function_privilege('authenticated', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: authenticated lost EXECUTE';
  END IF;

  IF has_function_privilege('anon', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: anon can still execute the contract';
  END IF;

  IF NOT has_function_privilege('service_role', v_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: service_role lost EXECUTE';
  END IF;

  SELECT p.prosrc INTO v_body
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'can_build_defense';

  IF v_body NOT LIKE '%AUTHENTICATION_REQUIRED%' OR v_body NOT LIKE '%PLAYER_NOT_OWNED%' THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: the ownership gate is missing';
  END IF;

  IF v_body NOT LIKE '%Shield dome already exists or is queued%' THEN
    RAISE EXCEPTION 'D02_POSTCONDITION_FAILED: an existing branch was lost in the rewrite';
  END IF;
END
$gate$;
