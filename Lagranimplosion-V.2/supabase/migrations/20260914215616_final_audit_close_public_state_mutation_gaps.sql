-- Final audit hardening: no client role may mutate authoritative tables directly.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE %I.%I FROM anon, authenticated', r.table_schema, r.table_name);
  END LOOP;
END $$;

-- Tables that were still outside RLS protection.
ALTER TABLE public.defense_prerequisites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.defense_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.universe_expansion_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.universe_galaxies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.universe_population_state ENABLE ROW LEVEL SECURITY;

-- These are authoritative/internal state tables. No direct Data API access.
DROP POLICY IF EXISTS deny_direct_api_access ON public.defense_prerequisites;
CREATE POLICY deny_direct_api_access ON public.defense_prerequisites
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS deny_direct_api_access ON public.defense_queue;
CREATE POLICY deny_direct_api_access ON public.defense_queue
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS deny_direct_api_access ON public.universe_expansion_state;
CREATE POLICY deny_direct_api_access ON public.universe_expansion_state
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS deny_direct_api_access ON public.universe_galaxies;
CREATE POLICY deny_direct_api_access ON public.universe_galaxies
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS deny_direct_api_access ON public.universe_population_state;
CREATE POLICY deny_direct_api_access ON public.universe_population_state
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- Internal workers/processors must never be callable by client roles.
REVOKE EXECUTE ON FUNCTION public.process_defense_queue(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.process_research_queue_for_player(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.process_research_queue_for_universe(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.process_universe_clock(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_planet_resources_until_raw(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- Keep the canonical authenticated/guest gameplay APIs intact; their bodies enforce ownership/guest rules.
GRANT EXECUTE ON FUNCTION public.start_defense(uuid, uuid, text, bigint) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_fleet_mixed(uuid, uuid, uuid, jsonb, text) TO anon, authenticated;
