-- =============================================================================
-- RECOVERED MIGRATION — 20260918094108
-- ledger name : harden_shipyard_queue_processing_ownership
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
  v_auth_user uuid;
  v_planet_player uuid;
  v_queue record;
begin
  v_auth_user := auth.uid();

  select p.player_id
    into v_planet_player
  from public.planets p
  where p.id = p_planet_id
    and not p.is_destroyed
  for update;

  if not found then
    raise exception 'Planet not found or destroyed';
  end if;

  if v_auth_user is not null then
    if not exists (
      select 1
      from public.players pl
      where pl.id = v_planet_player
        and pl.user_id = v_auth_user
    ) then
      raise exception 'Planet does not belong to authenticated user';
    end if;
  elsif not exists (
    select 1
    from public.players pl
    where pl.id = v_planet_player
      and coalesce(pl.is_guest, false)
  ) then
    raise exception 'Authentication required';
  end if;

  if p_until is null then
    raise exception 'Processing timestamp is required';
  end if;

  if p_until > now() then
    raise exception 'Cannot process shipyard queue into the future';
  end if;

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
grant execute on function public.process_shipyard_queue_until(uuid, timestamptz) to authenticated;

