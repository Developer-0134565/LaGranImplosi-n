-- FIX: resolve_colonize_arrival column/variable ambiguity on the colony-ship DELETE — LA GRAN IMPLOSIÓN
-- --------------------------------------------------------------------------------------------
-- The colonisation resolver returns TABLE(fleet_id, new_planet_id, galaxy, system, position, status),
-- so `fleet_id` is a PL/pgSQL OUT variable. Its DELETE referenced the bare column name:
--
--     DELETE FROM public.fleet_movement_ships
--     WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';
--
-- which PL/pgSQL rejects at runtime with 42702 (column reference "fleet_id" is ambiguous). This is a
-- PRE-EXISTING latent defect of the resolver: it was inherited unchanged by migration
-- 20260925171816 and it is exactly the statement that unloads the consumed colony ship, so the whole
-- colonisation arrival could never complete (LIVE has 0 planets named 'Colony %' and 0 COLONIZE
-- movements, consistent with the mission never having been reachable from the client).
--
-- Forward-only, minimal fix: qualify the column with a table alias. No behaviour change other than
-- the resolver now executing. Same exact-match, EOL-canonicalised substitution technique as the
-- previous migration.
DO $patch_colonize$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'resolve_colonize_arrival';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'COLONIZE-AMBIGUITY: resolve_colonize_arrival not found';
    END IF;

    v_old := $frag$    DELETE FROM public.fleet_movement_ships
    WHERE fleet_id=p_fleet_id AND ship_id='colony_ship';$frag$;

    v_new := $frag$    DELETE FROM public.fleet_movement_ships fms
    WHERE fms.fleet_id=p_fleet_id AND fms.ship_id='colony_ship';$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'COLONIZE-AMBIGUITY: DELETE fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_colonize$;
