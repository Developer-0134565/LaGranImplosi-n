-- PLANET TEMPERATURE — hardening: planet_temperature() always returns exactly one row (2026-09-30)
-- ================================================================================================
-- `20260930160000_planet_temperature_system.sql` defined `planet_temperature(planet)` as a CTE + lateral
-- join. For a planet that does not exist the CTE is EMPTY, so the function returned ZERO rows and a
-- `SELECT ... INTO` caller would silently receive NULL temperature — exactly the "accidental NULL" the
-- temperature mission forbids.
--
-- `calculate_planet_production` is safe (it raises on a missing planet first), but the helper is a public
-- contract and must not be able to hand out NULLs. This migration makes it TOTAL: it always returns one
-- row, falling back to the out-of-range band (0 / 20 / 10, i.e. upstream's fallback [0,40] midpoint) for an
-- unknown planet. The model itself is untouched; this only closes the zero-row hole.
--
-- The two creation paths and the four consumer formulas are NOT touched here.

begin;

create or replace function public.planet_temperature(p_planet_id uuid)
returns table (temperature_min integer, temperature_max integer, temperature_average integer)
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_stored_min integer;
    v_stored_max integer;
    v_position integer;
begin
    select p.temperature_min, p.temperature_max, p.position
      into v_stored_min, v_stored_max, v_position
      from public.planets p
     where p.id = p_planet_id;

    if v_stored_min is not null and v_stored_max is not null then
        temperature_min     := v_stored_min;
        temperature_max     := v_stored_max;
        temperature_average := (v_stored_min + v_stored_max) / 2;
    else
        -- NULL column or unknown planet: the position model, never a magic 0 and never NULL.
        select m.temperature_min, m.temperature_max, m.temperature_average
          into temperature_min, temperature_max, temperature_average
          from public.planet_temperature_for_position(coalesce(v_position, 0)) m;
    end if;
    return next;
end;
$function$;

revoke all on function public.planet_temperature(uuid) from public, anon, authenticated;
grant execute on function public.planet_temperature(uuid) to service_role;

do $$
declare
    v_rows integer;
begin
    select count(*) into v_rows from public.planet_temperature(gen_random_uuid());
    if v_rows <> 1 then
        raise exception 'TEMPERATURE_HARDENING: planet_temperature must always return exactly one row (got %)', v_rows;
    end if;
    if exists (select 1 from public.planet_temperature(gen_random_uuid()) t
               where t.temperature_min is null or t.temperature_max is null or t.temperature_average is null) then
        raise exception 'TEMPERATURE_HARDENING: planet_temperature returned a NULL temperature';
    end if;
end;
$$;

commit;
