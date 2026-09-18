-- Research lifecycle / availability contract regression tests.
-- All assertions are read-only and run inside a transaction that is rolled back.
-- Client-path checks use role authenticated with a real players.user_id claim.

BEGIN;

CREATE TEMP TABLE _research_fixture(
  player_id uuid,
  planet_id uuid,
  user_id uuid,
  research_id text,
  prereq_count integer,
  other_player uuid,
  other_planet uuid
) ON COMMIT DROP;

INSERT INTO _research_fixture
SELECT
  p.id,
  pl.id,
  p.user_id,
  (
    SELECT rp.research_id
    FROM public.research_prerequisites rp
    GROUP BY rp.research_id
    ORDER BY count(*) DESC, rp.research_id
    LIMIT 1
  ),
  (
    SELECT count(*)
    FROM public.research_prerequisites rp2
    WHERE rp2.research_id = (
      SELECT rp.research_id
      FROM public.research_prerequisites rp
      GROUP BY rp.research_id
      ORDER BY count(*) DESC, rp.research_id
      LIMIT 1
    )
  ),
  (SELECT p2.id FROM public.players p2 WHERE p2.id <> p.id LIMIT 1),
  (
    SELECT pl2.id
    FROM public.planets pl2
    WHERE pl2.player_id = (
      SELECT p2.id FROM public.players p2 WHERE p2.id <> p.id LIMIT 1
    )
      AND pl2.is_destroyed = false
    LIMIT 1
  )
FROM public.players p
JOIN public.planets pl
  ON pl.player_id = p.id
 AND pl.is_destroyed = false
WHERE p.user_id IS NOT NULL
LIMIT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM _research_fixture) THEN
    RAISE EXCEPTION 'RESEARCH_TEST_FIXTURE_NOT_FOUND';
  END IF;
END $$;

CREATE TEMP TABLE _research_results(
  assertion integer,
  name text,
  pass boolean
) ON COMMIT DROP;

GRANT SELECT, INSERT ON _research_fixture TO authenticated;
GRANT SELECT, INSERT ON _research_results TO authenticated;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT user_id::text FROM _research_fixture),
  true
);

SET LOCAL ROLE authenticated;

DO $$
DECLARE
  f record;
  r record;
  before_resources jsonb;
  after_resources jsonb;
  before_level integer;
  after_level integer;
  before_queue integer;
  after_queue integer;
BEGIN
  SELECT * INTO f FROM _research_fixture;

  -- 1. Owner can reach the contract and gets a structured result.
  SELECT * INTO r
  FROM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (1, 'owner contract returns result', r.reason_code IS NOT NULL);

  -- 2. Target level is derived by the server.
  INSERT INTO _research_results VALUES
    (2, 'target_level = current_level + 1', r.target_level = r.current_level + 1);

  -- 3. Protected prerequisites are visible to the DEFINER contract.
  INSERT INTO _research_results VALUES
    (3, 'prerequisite detail count', jsonb_array_length(r.prerequisites) = f.prereq_count);

  -- 4. An authenticated owner is not rejected as PLAYER_NOT_OWNED.
  INSERT INTO _research_results VALUES
    (4, 'owner passes ownership gate', r.reason_code <> 'PLAYER_NOT_OWNED');

  -- 5. The new contract is authenticated-only.
  INSERT INTO _research_results VALUES
    (5, 'can_start_research grant boundary',
      has_function_privilege('authenticated','public.can_start_research(uuid,uuid,text)','EXECUTE')
      AND NOT has_function_privilege('anon','public.can_start_research(uuid,uuid,text)','EXECUTE'));

  -- 6. Legacy helper APIs are closed to the client.
  INSERT INTO _research_results VALUES
    (6, 'legacy research helper APIs closed',
      NOT has_function_privilege('authenticated','public.check_research_requirements(uuid,text)','EXECUTE')
      AND NOT has_function_privilege('authenticated','public.get_research_requirements(uuid,text)','EXECUTE'));

  -- 7. can_research is now an internal helper, not a public API.
  INSERT INTO _research_results VALUES
    (7, 'can_research closed to client',
      NOT has_function_privilege('authenticated','public.can_research(uuid,text,integer)','EXECUTE'));

  -- 8-10. The availability contract is read-only.
  SELECT jsonb_build_object(
           'metal', metal, 'crystal', crystal, 'deuterium', deuterium
         )
  INTO before_resources
  FROM public.planet_resources
  WHERE planet_id = f.planet_id;

  SELECT level INTO before_level
  FROM public.player_research
  WHERE player_id = f.player_id
    AND research_id = f.research_id;

  SELECT count(*) INTO before_queue
  FROM public.research_queue
  WHERE player_id = f.player_id;

  PERFORM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  SELECT jsonb_build_object(
           'metal', metal, 'crystal', crystal, 'deuterium', deuterium
         )
  INTO after_resources
  FROM public.planet_resources
  WHERE planet_id = f.planet_id;

  SELECT level INTO after_level
  FROM public.player_research
  WHERE player_id = f.player_id
    AND research_id = f.research_id;

  SELECT count(*) INTO after_queue
  FROM public.research_queue
  WHERE player_id = f.player_id;

  INSERT INTO _research_results VALUES
    (8, 'resources unchanged', before_resources IS NOT DISTINCT FROM after_resources),
    (9, 'research level unchanged', before_level IS NOT DISTINCT FROM after_level),
    (10, 'queue unchanged', before_queue = after_queue);

  -- 11. Cross-player access is rejected before returning another player's data.
  SELECT * INTO r
  FROM public.can_start_research(f.other_player, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (11, 'foreign player rejected', r.reason_code = 'PLAYER_NOT_OWNED');

  -- 12. Missing auth is rejected before any protected data is returned.
  PERFORM set_config('request.jwt.claim.sub', null, true);

  SELECT * INTO r
  FROM public.can_start_research(f.player_id, f.planet_id, f.research_id);

  INSERT INTO _research_results VALUES
    (12, 'null auth rejected', r.reason_code = 'AUTHENTICATION_REQUIRED');
END $$;

RESET ROLE;

SELECT assertion, name, pass
FROM _research_results
ORDER BY assertion;

DO $$
DECLARE
  failures integer;
BEGIN
  SELECT count(*) INTO failures
  FROM _research_results
  WHERE NOT pass;

  IF failures <> 0 THEN
    RAISE EXCEPTION 'RESEARCH CONTRACT TEST FAILED: % assertion(s)', failures;
  END IF;
END $$;

ROLLBACK;
