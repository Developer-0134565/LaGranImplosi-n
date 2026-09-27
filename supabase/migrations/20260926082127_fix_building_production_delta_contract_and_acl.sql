-- BUILDINGS — repair `calculate_building_production_delta` and close its structurally unusable client surface.
-- --------------------------------------------------------------------------------------------
-- README_ECONOMY (BROKEN / NO CONSUMERS) recorded the defect verbatim: the helper selects
-- `r.economy_rate` / `r.production_rate`, but `calculate_universe_rates()` returns `economy` / `production`,
-- so every call raised `column r.economy_rate does not exist`. Verified LIVE on 2026-09-26: zero consumers
-- (no other function mentions it, `src/**` never calls it, the generated types only declare it).
--
-- This migration is a forward-only BUG FIX (the wrong column names are replaced by the real ones) and does
-- NOT touch the formula, the levels, the solar-plant exception or the return signature. Energy Technology /
-- lifeform / item bonuses and the energy-balance factor are deliberately still NOT applied here: this helper
-- is a gross production delta projection, exactly as its own comment states, not a second authority for the
-- planet's production (`calculate_planet_production` remains the only authority).
--
-- ACL: the helper is SECURITY INVOKER and reads `public.universes`, which has no SELECT grant for
-- `anon`/`authenticated`, so its client EXECUTE could never succeed (the old failure mode was "permission
-- denied for table universes" — the same reason `research_action_candidates` was retired as a client
-- contract). Instead of widening a grant over the universe rate table, the client surface is closed and the
-- helper is kept for internal/service-role use. No caller in the product is affected.

create or replace function public.calculate_building_production_delta(p_planet_id uuid, p_building_id text)
returns table(
    building_id text,
    current_level integer,
    target_level integer,
    metal_delta_per_hour numeric,
    crystal_delta_per_hour numeric,
    deuterium_delta_per_hour numeric,
    energy_delta_per_hour numeric
)
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_current_level integer := 0;
    v_target_level integer;
    v_current numeric := 0;
    v_target numeric := 0;
begin
    if not exists (
        select 1 from public.planets
        where id = p_planet_id and is_destroyed = false
    ) then
        raise exception 'Planet % does not exist or is destroyed', p_planet_id;
    end if;

    select coalesce(max(pb.level), 0)
    into v_current_level
    from public.planet_buildings pb
    where pb.planet_id = p_planet_id
      and pb.building_id = p_building_id;

    v_target_level := v_current_level + 1;

    if p_building_id = 'metal_mine' then
        v_current := 30 * v_current_level * power(1.1, v_current_level);
        v_target := 30 * v_target_level * power(1.1, v_target_level);
    elsif p_building_id = 'crystal_mine' then
        v_current := 20 * v_current_level * power(1.1, v_current_level);
        v_target := 20 * v_target_level * power(1.1, v_target_level);
    elsif p_building_id = 'deuterium_synthesizer' then
        v_current := 10 * v_current_level * power(1.1, v_current_level);
        v_target := 10 * v_target_level * power(1.1, v_target_level);
    elsif p_building_id = 'solar_plant' then
        v_current := 20 * v_current_level * power(1.1, v_current_level);
        v_target := 20 * v_target_level * power(1.1, v_target_level);
    else
        raise exception 'Building % does not directly produce resources', p_building_id;
    end if;

    /* Live universe rates apply to resource production, but NOT solar energy. */
    if p_building_id <> 'solar_plant' then
        select v_current * r.economy * r.production,
               v_target * r.economy * r.production
        into v_current, v_target
        from public.calculate_universe_rates(
            (select universe_id from public.planets where id = p_planet_id)
        ) r;
    end if;

    building_id := p_building_id;
    current_level := v_current_level;
    target_level := v_target_level;
    metal_delta_per_hour := 0;
    crystal_delta_per_hour := 0;
    deuterium_delta_per_hour := 0;
    energy_delta_per_hour := 0;

    case p_building_id
        when 'metal_mine' then metal_delta_per_hour := v_target - v_current;
        when 'crystal_mine' then crystal_delta_per_hour := v_target - v_current;
        when 'deuterium_synthesizer' then deuterium_delta_per_hour := v_target - v_current;
        when 'solar_plant' then energy_delta_per_hour := v_target - v_current;
    end case;

    return next;
end;
$function$;

comment on function public.calculate_building_production_delta(uuid, text) is
$c$Gross production-delta projection of the next level of a resource building (universe rates applied,
"energy is not rate scaled", no Energy Technology / lifeform / item bonus and no energy-balance factor).
Repaired 2026-09-26: it selected the non-existent columns r.economy_rate/r.production_rate of
calculate_universe_rates() and raised on every call. Internal/service-role only: it is SECURITY INVOKER and
reads universes, which has no client SELECT grant, so its former anon/authenticated EXECUTE surface was
unusable. calculate_planet_production stays the single production authority.
Certified by supabase/tests/building_production_delta_contract.sql.$c$;

revoke all on function public.calculate_building_production_delta(uuid, text) from public;
revoke all on function public.calculate_building_production_delta(uuid, text) from anon;
revoke all on function public.calculate_building_production_delta(uuid, text) from authenticated;
grant execute on function public.calculate_building_production_delta(uuid, text) to service_role;
