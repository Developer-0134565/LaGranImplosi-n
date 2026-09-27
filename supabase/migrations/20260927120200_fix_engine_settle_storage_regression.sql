-- ============================================================================
-- REGRESSION FIX — THE ENGINE SETTLE PATH MUST NOT DEPEND ON THE CALLER'S JWT (2026-09-27)
-- ----------------------------------------------------------------------------
-- FOUND LIVE 2026-09-27 while re-running the espionage certification (the counter-espionage fixture could not pass
-- any more). Reproduced, not inferred:
--
--     as the certification actor (request.jwt.claims set) -> resolve_espionage_arrival(<foreign target>)
--       ERROR: P0001: PLAYER_NOT_OWNED
--       CONTEXT: calculate_planet_storage(uuid) line 18 at RAISE
--                -> update_planet_resources_until_raw(uuid,timestamptz) line 64
--                -> update_planet_resources_until(uuid,timestamptz) line 24
--                -> resolve_espionage_arrival(uuid) line 42
--
-- CAUSE: `20260926280000_fix_planet_resources_and_storage_read_contract` correctly added the ownership gate
--   (`auth.uid() IS NOT NULL AND the planet is not owned by auth.uid() -> PLAYER_NOT_OWNED`) to the CLIENT contract
--   `calculate_planet_storage`, and its own comment states the gate is skipped "when auth.uid() IS NULL, which is
--   exactly the service/worker context (… espionage …) that legitimately settles foreign planets". That covers the
--   pg_cron workers but NOT the case the certification harness exercises: an engine settle path running inside a
--   session that carries a user JWT (`request.jwt.claims`), where the planet being settled belongs to the OTHER
--   player. The espionage arrival settles the TARGET planet, so the client gate aborts the whole resolution.
--
-- WHY IT MUST BE FIXED (no product decision involved)
--   * It is a demonstrable regression of a CLOSED system: the espionage resolver is certified by
--     `supabase/tests/counter_espionage.sql` and `supabase/tests/espionage_report_gating.sql`, and neither fixture
--     can pass any more, so the espionage certification is not reproducible.
--   * It is a structural landmine: an engine-internal settle becomes a function of the ambient authentication state.
--     Any future path (or a manually triggered tick) that settles a foreign planet while a JWT is present breaks the
--     entire arrival pipeline — arrivals, returns and completions — with a client-facing error.
--
-- FIX — the repository's own precedent (`can_start_building` + `evaluate_building_start_internal`): keep ONE
-- computation and split it into an internal helper and a gated client contract.
--
--   public.calculate_planet_storage_internal(p_planet_id)   the computation exactly as it is today, WITHOUT the
--                                                           ownership gate; SECURITY DEFINER, pinned search_path,
--                                                           ACL = service_role only (engine-internal).
--   public.calculate_planet_storage(p_planet_id)            UNCHANGED client contract: the certified ownership gate
--                                                           (still raising PLAYER_NOT_OWNED) and then delegation to
--                                                           the internal helper. Same signature, same return shape,
--                                                           same volatility, same ACL.
--   the engine-only consumers                             update_planet_resources,
--                                                           update_planet_resources_until_raw and
--                                                           execute_expedition_merchant_trade (all of them
--                                                           `authenticated = false`) are repointed to the internal
--                                                           helper. The client contracts that read the OWN planet
--                                                           (get_current_planet_resources, get_planet_economy_overview)
--                                                           keep using the gated one.
--
-- The formulas, the storage multiplier, the expedition-item bonus and the rounding are NOT touched: the client
-- contract is proven equal to the internal helper for every planet at the end of this migration.
--
-- Verified by `supabase/tests/espionage_read_contract_reveal_flags.sql` (which drives the real resolver) and by the
-- re-run of `supabase/tests/counter_espionage.sql` / `supabase/tests/espionage_report_gating.sql`.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. the internal computation (verbatim: only the ownership gate is removed)
-- ---------------------------------------------------------------------------
create or replace function public.calculate_planet_storage_internal(p_planet_id uuid)
returns table(metal_capacity numeric, crystal_capacity numeric, deuterium_capacity numeric)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_metal_level integer := 0;
  v_crystal_level integer := 0;
  v_deuterium_level integer := 0;
  v_storage_multiplier numeric := 1;
  v_item_bonus numeric := 0;
  v_player_id uuid;
BEGIN
  SELECT p.player_id, COALESCE(u.storage_multiplier,1)
  INTO v_player_id, v_storage_multiplier
  FROM public.planets p
  JOIN public.universes u ON u.id=p.universe_id
  WHERE p.id=p_planet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Planeta % no existe',p_planet_id; END IF;

  SELECT
    COALESCE(MAX(level) FILTER (WHERE building_id='metal_storage'),0),
    COALESCE(MAX(level) FILTER (WHERE building_id='crystal_storage'),0),
    COALESCE(MAX(level) FILTER (WHERE building_id='deuterium_tank'),0)
  INTO v_metal_level, v_crystal_level, v_deuterium_level
  FROM public.planet_buildings
  WHERE planet_id=p_planet_id;

  v_item_bonus:=public.get_active_expedition_item_effect(v_player_id,p_planet_id,'storage_percent');
  v_storage_multiplier:=v_storage_multiplier*(1+v_item_bonus/100);
  metal_capacity:=100000*power(2,v_metal_level)*v_storage_multiplier;
  crystal_capacity:=100000*power(2,v_crystal_level)*v_storage_multiplier;
  deuterium_capacity:=100000*power(2,v_deuterium_level)*v_storage_multiplier;
  RETURN NEXT;
END;
$function$;

comment on function public.calculate_planet_storage_internal(uuid) is
$c$The storage computation of the client contract without its ownership gate: SECURITY DEFINER, pinned search_path and
`service_role`-only, for ENGINE paths that legitimately settle a planet of another player (fleet arrival resolution,
economics ticks). Never exposed to `authenticated`/`anon`; client reads go through calculate_planet_storage.$c$;

revoke all on function public.calculate_planet_storage_internal(uuid) from public, anon, authenticated;
grant execute on function public.calculate_planet_storage_internal(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. the client contract keeps its certified gate and delegates (same signature/shape/ACL)
-- ---------------------------------------------------------------------------
create or replace function public.calculate_planet_storage(p_planet_id uuid)
returns table(metal_capacity numeric, crystal_capacity numeric, deuterium_capacity numeric)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_auth_user uuid := auth.uid();
begin
  IF v_auth_user IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.id = p_planet_id
      AND pl.user_id = v_auth_user
      AND NOT p.is_destroyed
  ) THEN
    RAISE EXCEPTION 'PLAYER_NOT_OWNED';
  END IF;

  return query select * from public.calculate_planet_storage_internal(p_planet_id);
end;
$function$;

comment on function public.calculate_planet_storage(uuid) is
$c$Bounded client read contract for the storage CAPACITIES of a planet: the caller must own it (PLAYER_NOT_OWNED otherwise),
then the certified computation is delegated to the engine-internal `calculate_planet_storage_internal`. The gate is
skipped when auth.uid() IS NULL (workers/service actor), exactly as `20260926280000` certified.$c$;

revoke all on function public.calculate_planet_storage(uuid) from public, anon, authenticated;
grant execute on function public.calculate_planet_storage(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. the engine-only consumers are repointed to the internal helper
--    (guarded substitution: the anchor must exist, the patch must be idempotent,
--     and the result must be byte-identical except for the callee name)
-- ---------------------------------------------------------------------------
do $patch$
declare
    v_fn text;
    v_src text;
    v_new text;
    v_after text;
    v_touched integer := 0;
begin
    foreach v_fn in array array['update_planet_resources_until_raw', 'update_planet_resources',
                                'execute_expedition_merchant_trade']
    loop
        select pg_get_functiondef(p.oid) into v_src
        from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.proname = v_fn;

        if v_src is null then
            raise exception 'SETTLE PATCH TARGET MISSING: %', v_fn;
        end if;

        if position('calculate_planet_storage_internal' in v_src) > 0 then
            continue;  -- already patched (idempotent)
        end if;

        if position('public.calculate_planet_storage(' in v_src) = 0 then
            raise exception 'SETTLE PATCH ANCHOR NOT FOUND in %', v_fn;
        end if;

        v_new := replace(v_src, 'public.calculate_planet_storage(', 'public.calculate_planet_storage_internal(');
        execute v_new;

        /* byte-preservation proof: the recreated definition must be exactly the patched text */
        select pg_get_functiondef(p.oid) into v_after
        from pg_proc p
        where p.pronamespace = 'public'::regnamespace and p.proname = v_fn;

        if v_after <> v_new then
            raise exception 'SETTLE PATCH DRIFT: the recreated % differs from the patched source', v_fn;
        end if;

        v_touched := v_touched + 1;
    end loop;

    if v_touched = 0 then
        raise notice 'SETTLE PATCH: every engine consumer was already repointed';
    else
        raise notice 'SETTLE PATCH: % engine consumer(s) repointed', v_touched;
    end if;

    /* postcondition: no engine-only consumer calls the gated client contract any more */
    for v_fn in select p.proname
                 from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname in ('update_planet_resources_until_raw', 'update_planet_resources',
                                    'execute_expedition_merchant_trade')
                  and pg_get_functiondef(p.oid) like '%public.calculate_planet_storage(%'
    loop
        raise exception 'SETTLE PATCH POST: % still calls the gated client contract', v_fn;
    end loop;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 4. postconditions — the economy is untouched and the gate is still certified
-- ---------------------------------------------------------------------------
do $post$
declare
    v_total integer;
    v_identical integer;
    v_bad integer;
begin
    /* (a) the internal helper is engine-only and the client contract keeps its certified ACL */
    if has_function_privilege('anon', 'public.calculate_planet_storage_internal(uuid)', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.calculate_planet_storage_internal(uuid)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.calculate_planet_storage_internal(uuid)', 'EXECUTE') then
        raise exception 'POST: calculate_planet_storage_internal ACL must be service_role only';
    end if;
    if has_function_privilege('anon', 'public.calculate_planet_storage(uuid)', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.calculate_planet_storage(uuid)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.calculate_planet_storage(uuid)', 'EXECUTE') then
        raise exception 'POST: calculate_planet_storage ACL changed';
    end if;

    /* (b) the client contract still carries the certified gate verbatim */
    if not exists (
        select 1 from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'calculate_planet_storage'
           and p.prosecdef
           and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=public, pg_temp%'
           and p.prosrc like '%PLAYER_NOT_OWNED%'
           and p.prosrc like '%pl.user_id = auth.uid()%'
    ) then
        raise exception 'POST: calculate_planet_storage lost its certified ownership gate';
    end if;
    if not exists (
        select 1 from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = 'calculate_planet_storage_internal'
           and p.prosecdef and p.prosrc not like '%PLAYER_NOT_OWNED%'
    ) then
        raise exception 'POST: calculate_planet_storage_internal must not carry the gate';
    end if;

    /* (c) NUMERIC EQUIVALENCE: the delegation must reproduce the certified values for every planet */
    select count(*) into v_total from public.planets p
     where not p.is_destroyed
       and exists (select 1 from public.planet_resources pr where pr.planet_id = p.id);

    select count(*) into v_identical
      from public.planets p
      cross join lateral public.calculate_planet_storage(p.id) c
      cross join lateral public.calculate_planet_storage_internal(p.id) i
     where not p.is_destroyed
       and exists (select 1 from public.planet_resources pr where pr.planet_id = p.id)
       and c.metal_capacity = i.metal_capacity
       and c.crystal_capacity = i.crystal_capacity
       and c.deuterium_capacity = i.deuterium_capacity;

    if v_identical <> v_total then
        raise exception 'POST: % of % planets report different capacities through the delegation', v_total - v_identical, v_total;
    end if;

    /* (d) no engine-only settle function depends on the ambient JWT any more */
    select count(*) into v_bad
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('update_planet_resources_until_raw', 'update_planet_resources',
                         'execute_expedition_merchant_trade')
       and pg_get_functiondef(p.oid) like '%public.calculate_planet_storage(%';
    if v_bad > 0 then
        raise exception 'POST: % engine settle function(s) still call the gated client contract', v_bad;
    end if;

    raise notice 'SETTLE FIX applied: % planet(s) verified byte-identical, engine paths now JWT-independent', v_total;
end;
$post$;

commit;
