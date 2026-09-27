-- ============================================================================
-- GAP A — PLANET RESOURCES / STORAGE: BOUNDED CLIENT READ CONTRACTS
-- ----------------------------------------------------------------------------
-- Problem, measured LIVE 2026-09-26 (reproduced, not inferred):
--
--   public.calculate_planet_storage(uuid) and public.get_current_planet_resources(uuid)
--   were SECURITY INVOKER with the default PUBLIC EXECUTE grant, so both were reachable by
--   `anon` and `authenticated` through the Data API — while both depend on public.universes,
--   which deliberately has NO client SELECT grant (invariant asserted by
--   20260922050734_shipyard_availability_contract_definer, post-condition "universes must not
--   be granted to client roles"). Every client call therefore aborted with an internal
--   permission error instead of a decision:
--
--     authenticated -> select * from public.calculate_planet_storage('<planet>')
--       ERROR 42501: permission denied for table universes
--       CONTEXT: planets p JOIN universes u ON u.id = p.universe_id
--                PL/pgSQL function calculate_planet_storage(uuid) line 10
--
--     authenticated -> select * from public.get_current_planet_resources('<planet>')
--       ERROR 42501: permission denied for table universes
--       CONTEXT: calculate_universe_rates(uuid) line 13 -> calculate_planet_production(uuid)
--                line 36 -> get_current_planet_resources(uuid) line 40
--
--   Both probes were executed LIVE inside a rolled-back authenticated session before this
--   migration; supabase/tests/planet_resources_storage_read_contract.sql reproduces them.
--
-- Design — the project's own pattern, no new infrastructure (identical to
-- 20260922050734 can_build_ship and 20260926240000 can_start_building):
--
--   client -> bounded SECURITY DEFINER contract -> internal helpers -> authoritative result
--
--   * both functions become SECURITY DEFINER with a fixed search_path and gain the ownership
--     gate the sibling contracts already use:
--         auth.uid() IS NOT NULL AND the planet is not owned by auth.uid() -> PLAYER_NOT_OWNED
--     The gate is deliberately skipped when auth.uid() IS NULL, which is exactly the
--     service/worker context (pg_cron fleet, combat, espionage, moon, wreck-field, AI and
--     ranking workers) that legitimately settles foreign planets.
--   * the ACL is reduced to the roles that need the contracts: authenticated + service_role
--     (+ the owner). anon loses EXECUTE, so an anonymous caller is refused by the ACL instead
--     of receiving an internal schema error.
--
-- The two bodies are patched with a guarded, byte-preserving substitution — the same
-- fail-closed technique used by 20260923095315_fix_participant_settlement_replay: this
-- migration reads the installed body, requires the anchor line to appear EXACTLY once,
-- inserts the gate, asserts `replace(new, gate, '') = old` and only then replaces the
-- function. No other byte of either body can drift: formulas, rounding, projections, error
-- texts, return shape and volatility are the certified ones untouched.
--
-- Explicitly NOT done in this migration:
--   * no GRANT SELECT ON public.universes (nor any new universe accessor);
--   * no change to the economy: costs, production rates, storage capacities, formulas,
--     rounding and settlement are untouched;
--   * no new parameter, column, return column or overload;
--   * no change to calculate_universe_rates / calculate_planet_production: the deferred P3
--     hygiene of the other PUBLIC INVOKER helpers stays exactly as 20260922050734 declared
--     it, so no foreign-planet oracle is created here either.
-- ============================================================================

do $lgi_gap_a$
declare
  v_target record;
  v_src text;
  v_new text;
  v_gate text;
  v_hits integer;
begin
  for v_target in
    select * from (values
      ('calculate_planet_storage',
       '  SELECT p.player_id, COALESCE(u.storage_multiplier,1)',
       '  ',
       'returns table(metal_capacity numeric, crystal_capacity numeric, deuterium_capacity numeric)'),
      ('get_current_planet_resources',
       '    SELECT pr.last_calculated_at, pr.metal, pr.crystal, pr.deuterium, pr.energy',
       '    ',
       'returns table(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, projected_metal numeric, projected_crystal numeric, projected_deuterium numeric)')
    ) as t(fname, anchor, indent, returns_clause)
  loop
    select p.prosrc into v_src
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = v_target.fname
       and pg_get_function_identity_arguments(p.oid) = 'p_planet_id uuid';

    if v_src is null then
      raise exception 'GAP-A FAIL-CLOSED: public.%(uuid) does not exist', v_target.fname;
    end if;

    /* idempotent: a re-run finds the gate already installed and leaves the body alone */
    if position('PLAYER_NOT_OWNED' in v_src) > 0 then
      raise notice 'GAP-A: % already carries the ownership gate', v_target.fname;
      continue;
    end if;

    v_hits := (length(v_src) - length(replace(v_src, v_target.anchor, ''))) / length(v_target.anchor);
    if v_hits <> 1 then
      raise exception 'GAP-A FAIL-CLOSED: expected exactly one anchor in %, found %', v_target.fname, v_hits;
    end if;

    v_gate := v_target.indent || 'IF auth.uid() IS NOT NULL AND NOT EXISTS (' || E'\n'
           || v_target.indent || '  SELECT 1' || E'\n'
           || v_target.indent || '  FROM public.planets p' || E'\n'
           || v_target.indent || '  JOIN public.players pl ON pl.id = p.player_id' || E'\n'
           || v_target.indent || '  WHERE p.id = p_planet_id' || E'\n'
           || v_target.indent || '    AND pl.user_id = auth.uid()' || E'\n'
           || v_target.indent || '    AND NOT p.is_destroyed' || E'\n'
           || v_target.indent || ') THEN' || E'\n'
           || v_target.indent || '  RAISE EXCEPTION ''PLAYER_NOT_OWNED'';' || E'\n'
           || v_target.indent || 'END IF;' || E'\n';

    /* keep the body's own end-of-line style (the installed bodies are stored with LF) */
    if position(E'\r\n' in v_src) > 0 then
      v_gate := replace(v_gate, E'\n', E'\r\n');
    end if;

    v_new := replace(v_src, v_target.anchor, v_gate || v_target.anchor);
    if replace(v_new, v_gate, '') <> v_src then
      raise exception 'GAP-A FAIL-CLOSED: the % substitution is not byte-preserving', v_target.fname;
    end if;

    execute format(
      'create or replace function public.%I(p_planet_id uuid) %s language plpgsql stable security definer set search_path to ''public'',''pg_temp'' as %L',
      v_target.fname, v_target.returns_clause, v_new);

    raise notice 'GAP-A: % is now a bounded definer (gate inserted, body preserved byte-for-byte)',
      v_target.fname;
  end loop;
end;
$lgi_gap_a$;

-- ---------------------------------------------------------------------------
-- ACL: both contracts serve clients, but only authenticated ones. The internal
-- consumers (can_build_ship, can_build_defense, project_planet_resources, the
-- fleet/merchant settlement helpers) keep working: they run either as the owner
-- (SECURITY DEFINER context) or as service_role.
-- ---------------------------------------------------------------------------
revoke all on function public.calculate_planet_storage(uuid) from public, anon, authenticated;
grant execute on function public.calculate_planet_storage(uuid) to authenticated, service_role;

revoke all on function public.get_current_planet_resources(uuid) from public, anon, authenticated;
grant execute on function public.get_current_planet_resources(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Post-conditions: prove the fix landed AND that nothing was widened.
-- ---------------------------------------------------------------------------
do $lgi_gap_a_post$
declare
  v_fn text;
  v_signature text;
  v_def boolean;
  v_owner text;
  v_cfg text;
  v_kind text;
  v_result text;
  v_sigs integer;
  v_anon boolean;
  v_auth boolean;
  v_svc boolean;
  v_expected text;
begin
  foreach v_fn in array array['calculate_planet_storage','get_current_planet_resources'] loop
    select p.prosecdef,
           pg_get_userbyid(p.proowner),
           coalesce(array_to_string(p.proconfig, ','), ''),
           case when p.provolatile = 's' then 'STABLE'
                when p.provolatile = 'i' then 'IMMUTABLE'
                else 'VOLATILE' end,
           pg_get_function_result(p.oid),
           pg_get_function_identity_arguments(p.oid)
      into v_def, v_owner, v_cfg, v_kind, v_result, v_signature
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = v_fn
       and pg_get_function_identity_arguments(p.oid) = 'p_planet_id uuid';

    if v_signature is null then
      raise exception 'GAP-A POST: public.% is missing', v_fn;
    end if;
    if v_def is distinct from true then
      raise exception 'GAP-A POST: % is not SECURITY DEFINER', v_fn;
    end if;
    if v_owner <> 'postgres' then
      raise exception 'GAP-A POST: % is owned by %, not postgres', v_fn, v_owner;
    end if;
    if v_cfg not like '%search_path=public, pg_temp%' then
      raise exception 'GAP-A POST: % has no pinned search_path (%)', v_fn, v_cfg;
    end if;
    if v_kind <> 'STABLE' then
      raise exception 'GAP-A POST: % changed volatility to %', v_fn, v_kind;
    end if;

    select count(*) into v_sigs
      from pg_proc p2
     where p2.pronamespace = 'public'::regnamespace and p2.proname = v_fn;
    if v_sigs <> 1 then
      raise exception 'GAP-A POST: % now has % signatures (an overload was introduced)', v_fn, v_sigs;
    end if;

    if not exists (
      select 1 from pg_proc p3
       where p3.pronamespace = 'public'::regnamespace and p3.proname = v_fn
         and p3.prosrc like '%PLAYER_NOT_OWNED%'
         and p3.prosrc like '%pl.user_id = auth.uid()%'
    ) then
      raise exception 'GAP-A POST: % has no ownership gate', v_fn;
    end if;

    v_expected := case v_fn
      when 'calculate_planet_storage' then
        'TABLE(metal_capacity numeric, crystal_capacity numeric, deuterium_capacity numeric)'
      else
        'TABLE(planet_id uuid, metal numeric, crystal numeric, deuterium numeric, energy numeric, elapsed_seconds numeric, projected_metal numeric, projected_crystal numeric, projected_deuterium numeric)'
    end;
    if v_result <> v_expected then
      raise exception 'GAP-A POST: % return shape changed: %', v_fn, v_result;
    end if;

    v_anon := has_function_privilege('anon', format('public.%I(uuid)', v_fn), 'EXECUTE');
    v_auth := has_function_privilege('authenticated', format('public.%I(uuid)', v_fn), 'EXECUTE');
    v_svc  := has_function_privilege('service_role', format('public.%I(uuid)', v_fn), 'EXECUTE');
    if v_anon or not v_auth or not v_svc then
      raise exception 'GAP-A POST: % ACL wrong (anon=%, authenticated=%, service_role=%)',
        v_fn, v_anon, v_auth, v_svc;
    end if;
  end loop;

  /* the universe configuration stays closed: no table grant, no new accessor */
  if has_table_privilege('anon', 'public.universes', 'SELECT')
     or has_table_privilege('authenticated', 'public.universes', 'SELECT') then
    raise exception 'GAP-A POST: universes must not be granted to client roles';
  end if;

  /* the root dependency was deliberately NOT touched */
  if not exists (
    select 1 from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'calculate_universe_rates'
       and not p.prosecdef
  ) then
    raise exception 'GAP-A POST: calculate_universe_rates was unexpectedly changed';
  end if;
end;
$lgi_gap_a_post$;
