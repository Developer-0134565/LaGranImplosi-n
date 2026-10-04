-- CRAWLER ENERGY BALANCE — the reported consumption must include the crawler term (2026-09-30)
-- ================================================================================================
-- Q13 (product decision, closed): CORRECT this bug. This does NOT change Q1.
--   Q1 STILL STANDS: ONLY the effective (capped) crawlers consume energy. No switch to "excess crawlers
--   consume" — that variant was explicitly rejected.
--
-- THE BUG (found while auditing the solar satellite, 2026-09-30)
--   `calculate_planet_production` computes
--       v_crawler_effective := least(ship_count, (metal+crystal+deuterium levels) * 8)
--       v_energy_consumption := building_consumption + v_crawler_effective * 50
--   and that consumption only throttles the production factor INSIDE that function.
--   `calculate_planet_energy_balance` — the contract the UI reads for "ENERGÍA PROD/CONS" — sums ONLY
--   `building_energy_definitions` over `planet_buildings`. A planet with 40 crawlers therefore reported
--   the same consumption as one with none, while its production was being throttled by 2 000 energy/h:
--   the number shown to the player contradicted the number the engine used.
--
-- THE FIX (one authority, no duplicated formula)
--   Extract the crawler term into `calculate_crawler_energy_consumption(planet)` and call it from BOTH
--   `calculate_planet_production` and `calculate_planet_energy_balance`. Production keeps EXACTLY the
--   value it had (same cap, same 50 energy per effective unit): this migration cannot change production,
--   only make the balance agree with it.
--
-- SCOPE: one new read-only helper, two callers repointed. No rule, threshold, cap or UI change (the UI
--   already reads the balance contract), no new RPC.
--
-- SECURITY: the helper is read-only, SECURITY INVOKER, fixed search_path, service_role only, the same
--   posture as `calculate_planet_production`.

begin;

-- ---------------------------------------------------------------- 1. the single crawler term
create or replace function public.calculate_crawler_energy_consumption(p_planet_id uuid)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    -- Q1: only EFFECTIVE (capped) crawlers consume. cap = (metal + crystal + deuterium levels) * 8.
    select least(
               coalesce((select sum(ps.quantity) from public.planet_ships ps
                          where ps.planet_id = p_planet_id and ps.ship_id = 'crawler'), 0),
               ( coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'metal_mine'), 0)
               + coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'crystal_mine'), 0)
               + coalesce((select max(pb.level) from public.planet_buildings pb
                           where pb.planet_id = p_planet_id and pb.building_id = 'deuterium_synthesizer'), 0)
               ) * 8
           ) * 50;
$function$;

revoke all on function public.calculate_crawler_energy_consumption(uuid) from public, anon, authenticated;
grant execute on function public.calculate_crawler_energy_consumption(uuid) to service_role;

-- ---------------------------------------------------------------- 2. repoint both callers at the helper
do $$
declare
    v_def text;
    v_new text;
begin
    -- 2.1 production: same arithmetic, now sourced from the helper.
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_planet_production';
    if v_def is null then raise exception 'CRAWLER_BALANCE: calculate_planet_production not found'; end if;
    v_new := replace(v_def,
        E'  v_energy_consumption := v_energy_consumption + (v_crawler_effective * 50);',
        E'  v_energy_consumption := v_energy_consumption + public.calculate_crawler_energy_consumption(p_planet_id);');
    if v_new = v_def then raise exception 'CRAWLER_BALANCE: production anchor not found'; end if;
    execute v_new;

    -- 2.2 the balance contract adds the same term. NOTE: this function's stored body uses CRLF, so the
    -- anchor is a single line and the insertion spells the line break out explicitly.
    select pg_get_functiondef(p.oid) into v_def from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_planet_energy_balance';
    if v_def is null then raise exception 'CRAWLER_BALANCE: calculate_planet_energy_balance not found'; end if;
    v_new := replace(v_def,
        E'    WHERE pb.planet_id = p_planet_id;',
        E'    WHERE pb.planet_id = p_planet_id;\r\n\r\n    v_consumption := v_consumption + public.calculate_crawler_energy_consumption(p_planet_id);');
    if v_new = v_def then raise exception 'CRAWLER_BALANCE: balance anchor not found'; end if;
    execute v_new;
end;
$$;

-- ---------------------------------------------------------------- 3. post-conditions (fail loudly)
do $$
declare
    v_p uuid;
    v_crawlers bigint;
    v_c_effective bigint;
    v_expected numeric;
    v_reported numeric;
begin
    select p.id into v_p from public.planets p where not p.is_destroyed and p.kind = 'PLANET' limit 1;
    if v_p is null then raise exception 'CRAWLER_BALANCE: no probe planet'; end if;

    if public.calculate_crawler_energy_consumption(v_p) <> 0 then
        raise exception 'CRAWLER_BALANCE: helper must be 0 with no crawlers';
    end if;

    -- 40 crawlers, mines 10/10/10 => cap 240, so all 40 are effective => 40 * 50
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_p, 'crawler', 40)
      on conflict (planet_id, ship_id) do update set quantity = 40;
    insert into public.planet_buildings(planet_id, building_id, level) values
        (v_p, 'metal_mine', 10), (v_p, 'crystal_mine', 10), (v_p, 'deuterium_synthesizer', 10)
      on conflict (planet_id, building_id) do update set level = 10;
    select coalesce(sum(ps.quantity), 0) into v_crawlers from public.planet_ships ps
     where ps.planet_id = v_p and ps.ship_id = 'crawler';
    v_c_effective := least(v_crawlers, 30::bigint * 8);
    v_expected := v_c_effective * 50;
    if v_crawlers <> 40 or v_c_effective <> 40 or v_expected <> 2000 then
        raise exception 'CRAWLER_BALANCE: probe setup drifted (%s crawlers, %s effective)', v_crawlers, v_c_effective;
    end if;
    if public.calculate_crawler_energy_consumption(v_p) <> v_expected then
        raise exception 'CRAWLER_BALANCE: helper returned % instead of %',
            public.calculate_crawler_energy_consumption(v_p), v_expected;
    end if;

    -- the balance must now report at least that much more consumption than before
    select b.energy_consumption_per_hour into v_reported from public.calculate_planet_energy_balance(v_p) b;
    if v_reported < v_expected then
        raise exception 'CRAWLER_BALANCE: reported consumption % is below the crawler term %',
            v_reported, v_expected;
    end if;

    -- both callers must use the shared helper (no second formula)
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'calculate_planet_energy_balance'
                      and p.prosrc ilike '%calculate_crawler_energy_consumption%') then
        raise exception 'CRAWLER_BALANCE: the balance contract does not include the crawler term';
    end if;
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = 'calculate_planet_production'
                      and p.prosrc ilike '%calculate_crawler_energy_consumption%') then
        raise exception 'CRAWLER_BALANCE: production does not use the shared helper';
    end if;
end;
$$;

commit;
