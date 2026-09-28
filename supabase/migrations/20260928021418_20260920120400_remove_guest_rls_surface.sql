-- ============================================================================
-- REMOVE GUEST RLS SURFACE  (forward-only)
-- ----------------------------------------------------------------------------
-- 1. Guest-only read policies (*_select_guest) are dropped: they granted read
--    access to anyone (anon/authenticated) or to any guest flag, never to an
--    owner.
-- 2. Shared policies that mixed an ownership branch with `is_guest` are
--    RECREATED keeping only their legitimate branches (own user, AI gallery
--    read, explicit DevPlayer id).
-- 3. defense_queue_owner_read had a guest-only predicate with no ownership
--    branch; it is rebased on ownership so it keeps protecting the owner's own
--    queue instead of exposing foreign non-destroyed planets.
--
-- Untouched: planets_select_access (public map read of non-destroyed planets),
-- player_achievements_owner_read (own), and every non-read policy.
-- ============================================================================

BEGIN;

-- 1) guest-only policies ---------------------------------------------------
DROP POLICY IF EXISTS players_select_guest ON public.players;
DROP POLICY IF EXISTS planets_select_guest ON public.planets;
DROP POLICY IF EXISTS planet_resources_select_guest ON public.planet_resources;
DROP POLICY IF EXISTS planet_buildings_select_guest ON public.planet_buildings;
DROP POLICY IF EXISTS planet_defenses_select_guest ON public.planet_defenses;
DROP POLICY IF EXISTS planet_ships_select_guest ON public.planet_ships;
DROP POLICY IF EXISTS player_research_select_guest ON public.player_research;
DROP POLICY IF EXISTS building_queue_select_guest ON public.building_queue;
DROP POLICY IF EXISTS research_queue_select_guest ON public.research_queue;
DROP POLICY IF EXISTS shipyard_queue_select_guest ON public.shipyard_queue;
DROP POLICY IF EXISTS fleet_movements_select_guest ON public.fleet_movements;
DROP POLICY IF EXISTS fleet_movement_ships_select_guest ON public.fleet_movement_ships;

-- 2) players: keep AI gallery read, explicit DevPlayer id and own identity ---
DROP POLICY IF EXISTS players_select_access ON public.players;
CREATE POLICY players_select_access ON public.players
  FOR SELECT TO anon, authenticated
  USING (
    id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'::uuid
    OR (player_type = 'AI')
    OR (user_id = (select auth.uid()))
  );

-- 3) own-data policies -----------------------------------------------------
DROP POLICY IF EXISTS planet_resources_select_access ON public.planet_resources;
CREATE POLICY planet_resources_select_access ON public.planet_resources
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = planet_resources.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS building_queue_select_access ON public.building_queue;
CREATE POLICY building_queue_select_access ON public.building_queue
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = building_queue.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS player_research_select_access ON public.player_research;
CREATE POLICY player_research_select_access ON public.player_research
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.players pl
      WHERE pl.id = player_research.player_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS research_queue_select_access ON public.research_queue;
CREATE POLICY research_queue_select_access ON public.research_queue
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.players pl
      WHERE pl.id = research_queue.player_id
        AND pl.user_id = (select auth.uid())
    )
  );

-- 4) defense queue: rebased on ownership (was guest-only) ------------------
DROP POLICY IF EXISTS defense_queue_owner_read ON public.defense_queue;
CREATE POLICY defense_queue_owner_read ON public.defense_queue
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = defense_queue.planet_id
        AND p.is_destroyed = false
        AND pl.user_id = (select auth.uid())
    )
  );

COMMIT;
