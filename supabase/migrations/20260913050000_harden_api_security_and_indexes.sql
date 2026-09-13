BEGIN;

-- Pin public functions to trusted schemas. Existing functions rely on
-- unqualified public objects, so keep public before pg_temp rather than using
-- an empty search_path.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema_name,
           p.proname AS function_name,
           pg_get_function_identity_arguments(p.oid) AS identity_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format(
      'ALTER FUNCTION %I.%I(%s) SET search_path = public, pg_temp',
      r.schema_name, r.function_name, r.identity_args
    );
  END LOOP;
END $$;

-- Internal workers/resolvers are not browser API entrypoints.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('process_fleet_movements',''),
      ('process_research_queue',''),
      ('process_shipyard_queue','uuid'),
      ('run_fleet_worker',''),
      ('resolve_combat','uuid'),
      ('resolve_combat_round','uuid'),
      ('resolve_expedition_aliens','uuid'),
      ('resolve_expedition_black_hole','uuid'),
      ('resolve_expedition_item','uuid'),
      ('resolve_expedition_merchant','uuid'),
      ('resolve_expedition_pirates','uuid'),
      ('run_expedition_combat','uuid'),
      ('repair_defenses_after_combat','uuid'),
      ('update_planet_resources_until','uuid,timestamptz'),
      ('enforce_player_write_access','')
    ) AS x(function_name, identity_args)
  LOOP
    EXECUTE format(
      'REVOKE EXECUTE ON FUNCTION public.%I(%s) FROM PUBLIC, anon, authenticated',
      r.function_name, r.identity_args
    );
  END LOOP;
END $$;

-- Static game definitions are public-read, but still protected by RLS.
ALTER TABLE public.building_energy_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ship_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ship_prerequisites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.universes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS building_energy_definitions_public_read ON public.building_energy_definitions;
CREATE POLICY building_energy_definitions_public_read
  ON public.building_energy_definitions FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS ship_definitions_public_read ON public.ship_definitions;
CREATE POLICY ship_definitions_public_read
  ON public.ship_definitions FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS ship_prerequisites_public_read ON public.ship_prerequisites;
CREATE POLICY ship_prerequisites_public_read
  ON public.ship_prerequisites FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS universes_public_read ON public.universes;
CREATE POLICY universes_public_read
  ON public.universes FOR SELECT TO anon, authenticated USING (true);

-- Internal state is no longer directly exposed through the Data API.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'building_definitions','building_prerequisites','combat_battles',
    'combat_debris_generations','combat_defense_repairs','combat_individual_units',
    'combat_rapidfire','combat_round_damage','combat_round_snapshot_units',
    'combat_round_units','combat_rounds','combat_shots','combat_unit_state',
    'debris_fields','defense_definitions','espionage_reports',
    'expedition_item_definitions','expedition_item_uses','expedition_resource_caps',
    'expedition_results','expedition_reward_budgets','expedition_settings',
    'expedition_ship_tiers','lifeform_building_definitions','lifeform_building_queue',
    'lifeform_definitions','lifeform_research_definitions','lifeform_research_queue',
    'planet_lifeform_buildings','planet_lifeform_research','planet_lifeforms',
    'player_expedition_items','player_expedition_merchants','player_expedition_modifiers',
    'player_lifeform_discoveries','research_definitions','research_prerequisites',
    'strict','universe_clock'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS deny_direct_api_access ON public.%I', t);
    EXECUTE format(
      'CREATE POLICY deny_direct_api_access ON public.%I AS RESTRICTIVE FOR ALL TO anon, authenticated USING (false) WITH CHECK (false)',
      t
    );
  END LOOP;
END $$;

-- Remove duplicate indexes while preserving constraint-backed unique indexes.
DROP INDEX IF EXISTS public.idx_building_queue_finishes;
DROP INDEX IF EXISTS public.ux_fleet_movement_ships_fleet_ship;
DROP INDEX IF EXISTS public.ux_planets_coordinates;

-- Cover the foreign keys reported by Performance Advisor.
CREATE INDEX IF NOT EXISTS idx_building_prerequisites_prerequisite_building_id ON public.building_prerequisites(prerequisite_building_id);
CREATE INDEX IF NOT EXISTS idx_building_queue_building_id ON public.building_queue(building_id);
CREATE INDEX IF NOT EXISTS idx_combat_battles_attacker_player_id ON public.combat_battles(attacker_player_id);
CREATE INDEX IF NOT EXISTS idx_combat_defense_repairs_defense_id ON public.combat_defense_repairs(defense_id);
CREATE INDEX IF NOT EXISTS idx_combat_defense_repairs_planet_id ON public.combat_defense_repairs(planet_id);
CREATE INDEX IF NOT EXISTS idx_espionage_reports_target_planet_id ON public.espionage_reports(target_planet_id);
CREATE INDEX IF NOT EXISTS idx_expedition_item_uses_item_id ON public.expedition_item_uses(item_id);
CREATE INDEX IF NOT EXISTS idx_expedition_item_uses_planet_id ON public.expedition_item_uses(planet_id);
CREATE INDEX IF NOT EXISTS idx_expedition_results_item_id ON public.expedition_results(item_id);
CREATE INDEX IF NOT EXISTS idx_fleet_movement_ships_ship_id ON public.fleet_movement_ships(ship_id);
CREATE INDEX IF NOT EXISTS idx_lifeform_building_queue_building_id ON public.lifeform_building_queue(building_id);
CREATE INDEX IF NOT EXISTS idx_lifeform_building_queue_planet_id ON public.lifeform_building_queue(planet_id);
CREATE INDEX IF NOT EXISTS idx_lifeform_research_queue_planet_id ON public.lifeform_research_queue(planet_id);
CREATE INDEX IF NOT EXISTS idx_lifeform_research_queue_research_id ON public.lifeform_research_queue(research_id);
CREATE INDEX IF NOT EXISTS idx_planet_buildings_building_id ON public.planet_buildings(building_id);
CREATE INDEX IF NOT EXISTS idx_planet_defenses_defense_id ON public.planet_defenses(defense_id);
CREATE INDEX IF NOT EXISTS idx_planet_lifeform_buildings_building_id ON public.planet_lifeform_buildings(building_id);
CREATE INDEX IF NOT EXISTS idx_planet_lifeforms_lifeform_id ON public.planet_lifeforms(lifeform_id);
CREATE INDEX IF NOT EXISTS idx_planet_ships_ship_id ON public.planet_ships(ship_id);
CREATE INDEX IF NOT EXISTS idx_player_expedition_items_item_id ON public.player_expedition_items(item_id);
CREATE INDEX IF NOT EXISTS idx_player_lifeform_discoveries_lifeform_id ON public.player_lifeform_discoveries(lifeform_id);
CREATE INDEX IF NOT EXISTS idx_player_research_research_id ON public.player_research(research_id);
CREATE INDEX IF NOT EXISTS idx_research_prerequisites_prerequisite_research_id ON public.research_prerequisites(prerequisite_research_id);
CREATE INDEX IF NOT EXISTS idx_research_queue_planet_id ON public.research_queue(planet_id);
CREATE INDEX IF NOT EXISTS idx_research_queue_research_id ON public.research_queue(research_id);
CREATE INDEX IF NOT EXISTS idx_ship_prerequisites_building_id ON public.ship_prerequisites(building_id);
CREATE INDEX IF NOT EXISTS idx_ship_prerequisites_research_id ON public.ship_prerequisites(research_id);
CREATE INDEX IF NOT EXISTS idx_shipyard_queue_planet_id ON public.shipyard_queue(planet_id);
CREATE INDEX IF NOT EXISTS idx_shipyard_queue_ship_id ON public.shipyard_queue(ship_id);

-- Optimize existing owner/guest SELECT policies.
DROP POLICY IF EXISTS player_research_select_own ON public.player_research;
DROP POLICY IF EXISTS player_research_select_guest ON public.player_research;
CREATE POLICY player_research_select_access
  ON public.player_research FOR SELECT TO anon, authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.players pl
      WHERE pl.id=player_research.player_id
        AND (pl.is_guest=true OR pl.user_id=(SELECT auth.uid()))
    )
  );

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['building_queue','planet_resources','planets','players','research_queue'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_select_guest',t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',t||'_select_own',t);
  END LOOP;
END $$;

CREATE POLICY building_queue_select_access
  ON public.building_queue FOR SELECT TO anon,authenticated
  USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id=p.player_id WHERE p.id=building_queue.planet_id AND (pl.is_guest=true OR pl.user_id=(SELECT auth.uid()))));

CREATE POLICY planet_resources_select_access
  ON public.planet_resources FOR SELECT TO anon,authenticated
  USING (EXISTS (SELECT 1 FROM public.planets p JOIN public.players pl ON pl.id=p.player_id WHERE p.id=planet_resources.planet_id AND (pl.is_guest=true OR pl.user_id=(SELECT auth.uid()))));

CREATE POLICY planets_select_access
  ON public.planets FOR SELECT TO anon,authenticated
  USING (EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=planets.player_id AND (pl.is_guest=true OR pl.user_id=(SELECT auth.uid()))));

CREATE POLICY players_select_access
  ON public.players FOR SELECT TO anon,authenticated
  USING (is_guest=true OR user_id=(SELECT auth.uid()));

CREATE POLICY research_queue_select_access
  ON public.research_queue FOR SELECT TO anon,authenticated
  USING (EXISTS (SELECT 1 FROM public.players pl WHERE pl.id=research_queue.player_id AND (pl.is_guest=true OR pl.user_id=(SELECT auth.uid()))));

-- Make the action/economic read models respect the RLS of their base tables.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT schemaname,viewname
    FROM pg_views
    WHERE schemaname='public'
      AND viewname IN (
        'building_action_candidates','research_action_candidates','action_candidates',
        'unified_action_candidates','empire_next_action','executable_action_candidates',
        'production_roi_candidates','normalized_action_candidates','next_action_explained',
        'temporal_action_candidates','scored_action_candidates','empire_economic_monitor',
        'economic_action_candidates','optimization_candidates','simulated_followup_actions',
        'action_economic_evaluation','executable_optimization_candidates','empire_energy_monitor',
        'action_energy_evaluation','next_action','empire_action_ranking'
      )
  LOOP
    EXECUTE format('ALTER VIEW %I.%I SET (security_invoker=true)',r.schemaname,r.viewname);
  END LOOP;
END $$;

COMMIT;
