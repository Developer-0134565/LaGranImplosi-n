-- =============================================================================
-- RECOVERED MIGRATION — 20260921114105
-- ledger name : 20260921130000_restore_owner_select_policies_after_guest_rls_removal
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-21 by the P0 RLS reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- -----------------------------------------------------------------------------
-- LIVE effect (independently verified read-only after the fact):
--   Replaced the last six guest-oriented SELECT policies (predicate `pl.is_guest = true`)
--   with owner-scoped SELECT policies on planet_buildings, planet_defenses, planet_ships,
--   shipyard_queue, fleet_movements and fleet_movement_ships. Ownership is derived from
--   auth.uid() -> players.user_id -> players.id -> planet / fleet. No is_guest branch,
--   no anonymous/public access, no hardcoded player UUID, RLS left ENABLED on all six.
-- Verification (transactional, rolled back, no residue):
--   DEV owner reads planet_buildings 2/2, planet_ships 1/1, shipyard_queue 1/1 (was 0/0/0);
--   a stranger authenticated session and anon both read 0 rows on all six tables.
-- =============================================================================

-- Restore owner-scoped SELECT access removed by the guest-RLS cleanup.
-- Scope: six previously guest-only gameplay tables.
-- No anonymous/public access is granted; ownership is tied to auth.uid().

DROP POLICY IF EXISTS planet_buildings_select_guest ON public.planet_buildings;
CREATE POLICY planet_buildings_select_access
  ON public.planet_buildings
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = planet_buildings.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS planet_defenses_select_guest ON public.planet_defenses;
CREATE POLICY planet_defenses_select_access
  ON public.planet_defenses
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = planet_defenses.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS planet_ships_select_guest ON public.planet_ships;
CREATE POLICY planet_ships_select_access
  ON public.planet_ships
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = planet_ships.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS shipyard_queue_select_guest ON public.shipyard_queue;
CREATE POLICY shipyard_queue_select_access
  ON public.shipyard_queue
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.planets p
      JOIN public.players pl ON pl.id = p.player_id
      WHERE p.id = shipyard_queue.planet_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS fleet_movements_select_guest ON public.fleet_movements;
CREATE POLICY fleet_movements_select_access
  ON public.fleet_movements
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.players pl
      WHERE pl.id = fleet_movements.player_id
        AND pl.user_id = (select auth.uid())
    )
  );

DROP POLICY IF EXISTS fleet_movement_ships_select_guest ON public.fleet_movement_ships;
CREATE POLICY fleet_movement_ships_select_access
  ON public.fleet_movement_ships
  FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.fleet_movements fm
      JOIN public.players pl ON pl.id = fm.player_id
      WHERE fm.id = fleet_movement_ships.fleet_id
        AND pl.user_id = (select auth.uid())
    )
  );
