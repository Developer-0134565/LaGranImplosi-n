-- ============================================================================
-- COMBAT ENGINE PHASE 2 — CB-04: PER-FLEET WORKER ERROR ISOLATION
-- ----------------------------------------------------------------------------
-- `process_fleet_movements` resolves EVERY due fleet inside ONE transaction and
-- raises hard exceptions for malformed fleets (missing holding window, missing
-- expedition rounds, an attack fleet with no ships, …). Phase 1 proved the
-- consequence: CB-06, one aborting expedition fleet, rolled back the whole tick
-- and repeated every second — head-of-line blocking of the entire fleet queue.
--
-- This migration wraps each fleet's processing in its own PL/pgSQL subtransaction
-- (a block with an EXCEPTION handler). A failing fleet is therefore rolled back
-- COMPLETELY — its combat stays atomic and no partial battle, loss, loot, repair
-- or debris can survive — while the remaining fleets of the same invocation are
-- processed normally.
--
-- Observability is explicit and NOT swallowed: every failure raises a WARNING
--   FLEET_RESOLUTION_FAILED fleet=<id> mission=<type> sqlstate=<code> error=<msg>
-- which lands in the Postgres logs (the same channel the worker already uses for
-- its DEFEND warning), and the fleet itself stays in its previous status
-- (OUTBOUND / HOLDING / RETURNING) so the next tick retries it: the surviving
-- OUTBOUND row whose arrives_at is already in the past is the queryable signal.
--
-- Preserved invariants: combat atomicity (per fleet), replay/idempotency guards
-- (untouched), economic settlement, return-fleet behaviour, global advisory lock,
-- worker semantics and the function signature (so run_fleet_worker and
-- process_universe_tick keep working unchanged).
-- ============================================================================

do $cb04$
declare
  v_def text;
  v_new text;
  v_old text;
  v_newf text;
  v_occ integer;
  r record;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  where p.pronamespace='public'::regnamespace and p.proname='process_fleet_movements';

  if v_def is null then
    raise exception 'CB-04: process_fleet_movements not found';
  end if;

  for r in
    select * from (values
      (1, 1,
       $o$    update public.fleet_movements
    set status='ARRIVED'
    where id=v.id and status='OUTBOUND';$o$,
       $n$    begin
      update public.fleet_movements
      set status='ARRIVED'
      where id=v.id and status='OUTBOUND';$n$),

      (2, 1,
       $o$    fleet_id:=v.id;
    previous_status:='OUTBOUND';
    new_status:=v_new_status;
    processed_at=clock_timestamp();
    return next;$o$,
       $n$    fleet_id:=v.id;
    previous_status:='OUTBOUND';
    new_status:=v_new_status;
    processed_at=clock_timestamp();
    return next;
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;$n$),

      (3, 1,
       $o$    if v.holding_until is null or v.holding_until<=v.arrives_at then$o$,
       $n$    begin
      if v.holding_until is null or v.holding_until<=v.arrives_at then$n$),

      (4, 1,
       $o$    fleet_id:=v.id;
    previous_status:='HOLDING';
    new_status:='RETURNING';
    processed_at=clock_timestamp();
    return next;$o$,
       $n$    fleet_id:=v.id;
    previous_status:='HOLDING';
    new_status:='RETURNING';
    processed_at=clock_timestamp();
    return next;
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;$n$),

      (5, 1,
       $o$    if v.mission_type='EXPEDITION' then
      perform public.resolve_expedition_return(v.id);$o$,
       $n$    begin
      if v.mission_type='EXPEDITION' then
      perform public.resolve_expedition_return(v.id);$n$),

      (6, 1,
       $o$    fleet_id:=v.id;
    previous_status:='RETURNING';
    new_status=(select status from public.fleet_movements where id=v.id);
    processed_at=clock_timestamp();
    return next;$o$,
       $n$    fleet_id:=v.id;
    previous_status:='RETURNING';
    new_status=(select status from public.fleet_movements where id=v.id);
    processed_at=clock_timestamp();
    return next;
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;$n$)
    ) as t(ord, expected, old_frag, new_frag) order by ord
  loop
    -- prosrc stores CRLF; the fragments above are written with LF.
    v_old := replace(r.old_frag, chr(10), chr(13)||chr(10));
    v_newf := replace(r.new_frag, chr(10), chr(13)||chr(10));

    v_occ := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_occ <> r.expected then
      raise exception 'CB-04: fragment % matched % time(s), expected %', r.ord, v_occ, r.expected;
    end if;

    -- accumulate only: every intermediate state of the definition is
    -- syntactically incomplete (a `begin` without its handler), so the function is
    -- recreated exactly once, after all fragments have been applied.
    v_def := replace(v_def, v_old, v_newf);
  end loop;

  if (length(v_def) - length(replace(v_def, 'FLEET_RESOLUTION_FAILED', ''))) / length('FLEET_RESOLUTION_FAILED') <> 3 then
    raise exception 'CB-04: expected three per-fleet exception handlers';
  end if;

  execute v_def;
end
$cb04$;
