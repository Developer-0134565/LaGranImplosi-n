-- ============================================================================================
-- LGI - fix start_fleet: OUT-parameter / column ambiguity that broke EVERY single-ship dispatch
-- ============================================================================================
-- Defect (reproduced LIVE 2026-09-26, P0, found by the Supabase<->frontend contract audit):
--   start_fleet(...) raised  ERROR 42702: column reference "ship_id" is ambiguous  for EVERY mission,
--   because the ship-consumption UPDATE referenced the planet_ships columns unqualified while the
--   function's RETURNS TABLE declares OUT parameters with the same names (ship_id, quantity):
--     before:  UPDATE public.planet_ships SET quantity=quantity-p_quantity WHERE planet_id=p_origin_planet_id AND ship_id=p_ship_id;
--     after:   UPDATE public.planet_ships AS ps SET quantity = ps.quantity - p_quantity WHERE ps.planet_id = p_origin_planet_id AND ps.ship_id = p_ship_id;
-- Affected frontend paths: GalaxyView "ENVIAR FLOTA" (ATTACK/TRANSPORT/ESPIONAGE) and "ENVIAR EXPEDICIÓN".
-- start_fleet_mixed (App.tsx main fleet view) was already qualified and kept working, which is why the
-- defect stayed hidden.
-- The long function body is NOT duplicated here: this migration patches the LIVE definition from its own
-- text, verifying the exact pre-state statement first (idempotent, fails loudly on any unexpected shape).
-- ============================================================================================

do $fix$
declare
    v_def text; v_stmt text; v_patch text; v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'start_fleet';

    if v_def is null then
        raise exception 'start_fleet not found';
    end if;

    select (regexp_matches(v_def, 'UPDATE public\.planet_ships[^;]*;'))[1] into v_stmt;
    v_patch := 'UPDATE public.planet_ships AS ps SET quantity = ps.quantity - p_quantity WHERE ps.planet_id = p_origin_planet_id AND ps.ship_id = p_ship_id;';

    if v_stmt is null then
        raise exception 'start_fleet: ship UPDATE statement not found';
    end if;
    if v_stmt = v_patch then
        raise notice 'start_fleet already patched';
        return;
    end if;
    if position('ship_id=p_ship_id' in v_stmt) = 0 then
        raise exception 'start_fleet: unexpected statement [%], refusing to patch', v_stmt;
    end if;

    v_new := replace(v_def, v_stmt, v_patch);
    if v_new = v_def then
        raise exception 'start_fleet: replacement had no effect';
    end if;

    execute v_new;
    raise notice 'start_fleet patched: OUT-parameter/column ambiguity removed';
end;
$fix$;