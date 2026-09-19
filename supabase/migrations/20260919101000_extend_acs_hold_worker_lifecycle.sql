-- ============================================================================
-- ACS_HOLD / HOLDING — FASE A (worker lifecycle extension)
-- ----------------------------------------------------------------------------
-- Extends the EXISTING resolver (process_fleet_movements) instead of adding a
-- parallel worker. Only two behaviours change:
--
--   OUTBOUND -> ARRIVED -> HOLDING
--       ACS_HOLD / HOLDING must carry a valid holding window
--       (holding_until not null and strictly after arrives_at). An invalid
--       window aborts the transition inside the worker transaction, so the
--       movement can never remain ARRIVED with a partially initialised hold.
--
--   DEFEND
--       Combat support is not implemented. A DEFEND row can no longer be
--       created by any live path (start_support_fleet rejects it and the
--       dispatchers only accept the seven implemented missions), and this
--       worker deliberately refuses to advance a stray DEFEND row into
--       HOLDING: it stays ARRIVED and reports a WARNING instead of silently
--       entering a combat-less hold window or aborting the whole worker batch.
--
--   HOLDING -> RETURNING
--       Unchanged rule: now() >= holding_until, then returns_at is built from
--       the PERSISTED outbound duration. No speed/mission/evolution/fuel is
--       recalculated and the hold is never extended automatically.
--
-- The rest of the worker (RECYCLE, EXPEDITION, TRANSPORT, DEPLOY, ATTACK,
-- ESPIONAGE, COLONIZE, return settlement) is preserved verbatim from
-- 20260919053220_add_fleet_holding_lifecycle.
-- ============================================================================

BEGIN;

CREATE INDEX IF NOT EXISTS fleet_movements_outbound_arrival_idx
  ON public.fleet_movements(arrives_at, id)
  WHERE status='OUTBOUND';

CREATE INDEX IF NOT EXISTS fleet_movements_returning_idx
  ON public.fleet_movements(returns_at, id)
  WHERE status='RETURNING';

CREATE OR REPLACE FUNCTION public.process_fleet_movements()
RETURNS TABLE(fleet_id uuid, previous_status text, new_status text, processed_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v record;
  v_duration interval;
  v_battle uuid;
  v_last_round integer;
  v_recycle record;
  v_new_status text;
begin
  perform pg_advisory_xact_lock(hashtextextended('fleet-processing-global', 0));

  for v in
    select fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,
           fm.holding_until,
           fm.destination_galaxy,fm.destination_system,fm.destination_position
    from public.fleet_movements fm
    where fm.status='OUTBOUND'
      and fm.arrives_at<=clock_timestamp()
    order by fm.arrives_at,fm.id
    for update skip locked
  loop
    v_duration := v.arrives_at-v.started_at;

    update public.fleet_movements
    set status='ARRIVED'
    where id=v.id and status='OUTBOUND';

    if not found then
      continue;
    end if;

    if v.mission_type='DEFEND' then
      raise warning 'DEFEND movement % arrived but combat support is not implemented; kept in ARRIVED',v.id;

    elsif v.mission_type in ('ACS_HOLD','HOLDING') then
      if v.holding_until is null then
        raise exception 'SUPPORT_HOLDING_WINDOW_MISSING: fleet % of type % has no holding_until',v.id,v.mission_type;
      end if;

      if v.holding_until<=v.arrives_at then
        raise exception 'SUPPORT_HOLDING_WINDOW_INVALID: fleet % holding_until % is not after arrives_at %',
          v.id,v.holding_until,v.arrives_at;
      end if;

      update public.fleet_movements
      set status='HOLDING'
      where id=v.id and status='ARRIVED';

    elsif v.mission_type='RECYCLE' then
      select * into v_recycle
      from public.collect_debris(v.id,v.destination_galaxy,v.destination_system,v.destination_position);

      update public.fleet_movements
      set metal=coalesce(v_recycle.out_metal_collected,0),
          crystal=coalesce(v_recycle.out_crystal_collected,0),
          deuterium=0,
          status='RETURNING',
          returns_at=v.arrives_at+v_duration
      where id=v.id and status='ARRIVED';
    elsif v.mission_type='EXPEDITION' then
      perform public.resolve_expedition_arrival(v.id);

      select er.battle_id into v_battle
      from public.expedition_results er
      where er.fleet_id=v.id
        and er.outcome in ('PIRATES','ALIENS');

      if v_battle is not null then
        select max(cr.round_number) into v_last_round
        from public.combat_rounds cr
        where cr.battle_id=v_battle;

        if v_last_round is null then
          raise exception 'Expedition battle % finished without rounds',v_battle;
        end if;

        delete from public.fleet_movement_ships where fleet_id=v.id;

        insert into public.fleet_movement_ships(fleet_id,ship_id,quantity)
        select v.id,ciu.unit_id,count(*)::bigint
        from public.combat_individual_units ciu
        where ciu.battle_id=v_battle
          and ciu.round_number=v_last_round
          and ciu.side='ATTACKER'
          and ciu.unit_type='SHIP'
          and ciu.alive
        group by ciu.unit_id
        on conflict(fleet_id,ship_id)
        do update set quantity=excluded.quantity;

        update public.expedition_results er
        set ships=(select coalesce(jsonb_object_agg(fms2.ship_id,fms2.quantity),'{}')
                   from public.fleet_movement_ships fms2
                   where fms2.fleet_id=v.id),
            resolved_at=coalesce(er.resolved_at,clock_timestamp())
        where er.fleet_id=v.id;
      end if;

    elsif v.mission_type='TRANSPORT' then
      perform public.resolve_transport_arrival(v.id);

    elsif v.mission_type='DEPLOY' then
      perform public.resolve_deploy_arrival(v.id);

    elsif v.mission_type='ATTACK' then
      perform public.resolve_attack_arrival(v.id);

    elsif v.mission_type='ESPIONAGE' then
      perform public.resolve_espionage_arrival(v.id);

    elsif v.mission_type='COLONIZE' then
      perform public.resolve_colonize_arrival(v.id);

    else
      update public.fleet_movements
      set status='RETURNING',returns_at=v.arrives_at+v_duration
      where id=v.id and status='ARRIVED';
    end if;

    select status into v_new_status
    from public.fleet_movements
    where id=v.id;

    fleet_id:=v.id;
    previous_status:='OUTBOUND';
    new_status:=v_new_status;
    processed_at=clock_timestamp();
    return next;
  end loop;

  for v in
    select fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,fm.holding_until
    from public.fleet_movements fm
    where fm.status='HOLDING'
      and fm.holding_until<=clock_timestamp()
    order by fm.holding_until,fm.id
    for update skip locked
  loop
    if v.holding_until is null or v.holding_until<=v.arrives_at then
      raise exception 'SUPPORT_HOLDING_WINDOW_INVALID: fleet % has no usable holding window',v.id;
    end if;

    v_duration := v.arrives_at-v.started_at;

    update public.fleet_movements
    set status='RETURNING',
        returns_at=v.holding_until+v_duration
    where id=v.id and status='HOLDING';

    if not found then
      continue;
    end if;

    fleet_id:=v.id;
    previous_status:='HOLDING';
    new_status:='RETURNING';
    processed_at=clock_timestamp();
    return next;
  end loop;

  for v in
    select fm.id,fm.status,fm.mission_type,fm.returns_at
    from public.fleet_movements fm
    where fm.status='RETURNING'
      and fm.returns_at<=clock_timestamp()
    order by fm.returns_at,fm.id
    for update skip locked
  loop
    if v.mission_type='EXPEDITION' then
      perform public.resolve_expedition_return(v.id);
    end if;

    if v.mission_type<>'EXPEDITION'
       or exists(select 1 from public.fleet_movements where id=v.id and status='RETURNING')
    then
      if v.mission_type<>'EXPEDITION' then
        perform public.update_planet_resources_until(
          (select fm.origin_planet_id from public.fleet_movements fm where fm.id=v.id),
          v.returns_at
        );
      end if;

      insert into public.planet_ships(planet_id,ship_id,quantity)
      select fm.origin_planet_id,fms.ship_id,fms.quantity
      from public.fleet_movements fm
      join public.fleet_movement_ships fms on fms.fleet_id=fm.id
      where fm.id=v.id
      on conflict(planet_id,ship_id)
      do update set quantity=public.planet_ships.quantity+excluded.quantity;

      update public.planet_resources pr
      set metal=pr.metal+fm.metal,
          crystal=pr.crystal+fm.crystal,
          deuterium=pr.deuterium+fm.deuterium,
          updated_at=clock_timestamp()
      from public.fleet_movements fm
      where fm.id=v.id
        and pr.planet_id=fm.origin_planet_id
        and (fm.metal<>0 or fm.crystal<>0 or fm.deuterium<>0);

      update public.fleet_movements
      set metal=0,crystal=0,deuterium=0,status='COMPLETED'
      where id=v.id and status='RETURNING';
    end if;

    fleet_id:=v.id;
    previous_status:='RETURNING';
    new_status=(select status from public.fleet_movements where id=v.id);
    processed_at=clock_timestamp();
    return next;
  end loop;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.process_fleet_movements() FROM PUBLIC, anon, authenticated;

COMMIT;
