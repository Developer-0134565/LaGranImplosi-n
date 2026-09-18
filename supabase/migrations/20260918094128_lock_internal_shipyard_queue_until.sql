-- =============================================================================
-- RECOVERED MIGRATION — 20260918094128
-- ledger name : lock_internal_shipyard_queue_until
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

create or replace function public.process_shipyard_queue_until(
  p_planet_id uuid,
  p_until timestamptz
)
returns table(
  queue_id uuid,
  ship_id text,
  quantity bigint,
  status text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_queue record;
begin
  for v_queue in
    select
      sq.id,
      sq.planet_id,
      sq.ship_id as queued_ship_id,
      sq.quantity as queued_quantity,
      sq.finishes_at
    from public.shipyard_queue sq
    where sq.planet_id = p_planet_id
      and sq.status = 'BUILDING'
      and sq.finishes_at <= p_until
    order by sq.finishes_at, sq.created_at, sq.id
    for update skip locked
  loop
    insert into public.planet_ships as ps(planet_id, ship_id, quantity)
    values(v_queue.planet_id, v_queue.queued_ship_id, v_queue.queued_quantity)
    on conflict on constraint planet_ships_pkey
    do update set quantity = ps.quantity + excluded.quantity;

    update public.shipyard_queue sq
       set status = 'COMPLETED'
     where sq.id = v_queue.id
       and sq.status = 'BUILDING';

    queue_id := v_queue.id;
    ship_id := v_queue.queued_ship_id;
    quantity := v_queue.queued_quantity;
    status := 'COMPLETED';
    return next;
  end loop;
end;
$function$;

revoke execute on function public.process_shipyard_queue_until(uuid, timestamptz) from public;
revoke execute on function public.process_shipyard_queue_until(uuid, timestamptz) from anon;
revoke execute on function public.process_shipyard_queue_until(uuid, timestamptz) from authenticated;

