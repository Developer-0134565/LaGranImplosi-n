-- =====================================================================
-- COLONY CAP (astrophysics) — LGI ↔ OGameX (owner-approved 2026-09-26)
-- =====================================================================
-- OGameX reference: app/GameObjects/ResearchObjects.php declares
--     $astrophysics->addCalculation(CalculationType::MAX_COLONIES, fn (int $level) => round($level / 2));
--   and app/GameMessages/ColonyEstablishFailAstrophysics.php is the "no slots left" outcome.
-- OGameX does not publish the base count next to that calculation, so the rule adopted here is stated
-- explicitly (balanced, playable from turn one):
--     max PLANETS = 1 (homeworld) + max(1, round(astrophysics / 2))
--   i.e. every player can always found one colony, and Astrophysics is the growth lever
--   (astro 0 -> 2 slots, 4 -> 3, 8 -> 5, 10 -> 6, 20 -> 11).
--   Moons never count against the cap and destroyed planets never count.
-- Enforcement (two points, so the rule can not be bypassed by fleets already in flight):
--   1. start_colonize_fleet()  → dispatch gate (OGameX ColonyEstablishFailAstrophysics).
--   2. resolve_colonize_arrival() → authoritative creation gate (defensive, race-safe).
-- =====================================================================

create or replace function public.calculate_max_colony_slots(p_player_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select 1 + greatest(1, round(coalesce(public.get_player_research_level(p_player_id, 'astrophysics'), 0) / 2.0)::integer);
$function$;

create or replace function public.check_colony_cap(p_player_id uuid)
returns table(allowed boolean, reason text, max_slots integer, current_planets integer, astrophysics_level integer)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_astro integer;
    v_max integer;
    v_current integer;
begin
    v_astro := coalesce(public.get_player_research_level(p_player_id, 'astrophysics'), 0);
    v_max := public.calculate_max_colony_slots(p_player_id);

    select count(*) into v_current
      from public.planets p
     where p.player_id = p_player_id
       and p.kind = 'PLANET'
       and p.is_destroyed = false;

    return query select
        (v_current < v_max),
        case when v_current < v_max then 'OK' else 'COLONY_CAP_REACHED' end,
        v_max,
        v_current,
        v_astro;
end;
$function$;

-- ---------------------------------------------------------------------
-- PATCH 1/2 — dispatch gate in start_colonize_fleet() (OGameX failure message).
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_colonize_fleet';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: start_colonize_fleet';
    end if;
    if position('COLONY_CAP_REACHED' in v_src) > 0 then
        return;
    end if;

    v_old := 'THEN raise exception ''COLONIZE_TARGET_OCCUPIED''; END IF;';
    v_new := 'THEN raise exception ''COLONIZE_TARGET_OCCUPIED''; END IF;' || chr(10) ||
             '   IF NOT coalesce((select cc.allowed from public.check_colony_cap(p_player_id) cc), false) THEN raise exception ''COLONY_CAP_REACHED''; END IF;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: start_colonize_fleet occupied check';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ---------------------------------------------------------------------
-- PATCH 2/2 — creation gate in resolve_colonize_arrival() (race-safe).
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resolve_colonize_arrival';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: resolve_colonize_arrival';
    end if;
    if position('COLONY_CAP_REACHED' in v_src) > 0 then
        return;
    end if;

    v_old := 'INSERT INTO public.planets(';
    v_new := 'IF NOT coalesce((select cc.allowed from public.check_colony_cap(v_fleet.player_id) cc), false) THEN raise exception ''COLONY_CAP_REACHED''; END IF;' || chr(10) ||
             '      INSERT INTO public.planets(';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: resolve_colonize_arrival creation insert';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ACL: preview contract for owners and the service actor; no anon.
revoke all on function public.calculate_max_colony_slots(uuid) from public;
revoke all on function public.check_colony_cap(uuid) from public;

grant execute on function public.calculate_max_colony_slots(uuid) to authenticated, service_role;
grant execute on function public.check_colony_cap(uuid) to authenticated, service_role;
