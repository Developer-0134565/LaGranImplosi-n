-- ============================================================================================
-- LGI - fix process_fleet_movements: OUT-parameter / column ambiguity in the battle branch
-- ============================================================================================
-- Found by the integral Supabase<->frontend contract audit (2026-09-26), same defect class as
-- 20260926250000_fix_start_fleet_out_param_column_ambiguity.sql.
--
-- process_fleet_movements declares OUT parameters through
--   RETURNS TABLE (fleet_id uuid, previous_status text, new_status text, processed_at timestamptz)
-- and the battle/recycle branch of its loop referenced the fleet_movement_ships column unqualified:
--   before:  delete from public.fleet_movement_ships where fleet_id=v.id;
--   after:   delete from public.fleet_movement_ships as fms where fms.fleet_id = v.id;
-- The ambiguity was PROVEN with a local reproducer (a temporary function with an OUT parameter named
-- fleet_id and the same statement raises: column reference "fleet_id" is ambiguous).
--
-- NOTE / OPEN ITEM (recorded, not resolved here): the worker isolates every fleet in a BEGIN/EXCEPTION
-- block and silently `continue`s, so any statement error inside the loop is invisible. In the audit
-- harness the worker still returned zero rows for a due OUTBOUND/RETURNING fleet even after this patch,
-- and the swallowed failure was NOT isolated (resolve_transport_arrival works when called directly with
-- the fleet in ARRIVED state -> RETURNING). The next session must instrument the loop (or temporarily
-- surface the swallowed error) to finish that diagnosis.
-- ============================================================================================

do $fix$
declare
    v_def text; v_stmt text; v_patch text; v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'process_fleet_movements';

    if v_def is null then
        raise exception 'process_fleet_movements not found';
    end if;

    select (regexp_matches(v_def, 'delete from public\.fleet_movement_ships[^;]*;'))[1] into v_stmt;
    v_patch := 'delete from public.fleet_movement_ships as fms where fms.fleet_id = v.id;';

    if v_stmt is null then
        raise exception 'worker: ship delete statement not found';
    end if;
    if v_stmt = v_patch then
        raise notice 'already patched';
        return;
    end if;
    if position('where fleet_id=v.id' in v_stmt) = 0 then
        raise exception 'unexpected statement [%], refusing to patch', v_stmt;
    end if;

    v_new := replace(v_def, v_stmt, v_patch);
    if v_new = v_def then
        raise exception 'replacement had no effect';
    end if;

    execute v_new;
    raise notice 'process_fleet_movements patched: OUT-parameter/column ambiguity removed';
end;
$fix$;