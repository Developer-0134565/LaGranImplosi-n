-- A fleet that reaches its return event AFTER the origin planet's production clock already moved
-- past that event can never be settled, and its ships are lost forever.
--
-- THE DEFECT (measured on LIVE, 2026-09-30)
--   The RETURNING branch of `process_fleet_movements` settled the origin planet with
--
--       perform public.update_planet_resources_until(origin_planet_id, v.returns_at);
--
--   and `update_planet_resources_until` deliberately refuses to move a planet's clock BACKWARDS
--   (it raises INVALID_RESOURCE_TIMESTAMP). That guard is correct and stays untouched.
--
--   The bug is that the worker treats a past `returns_at` as a hard error, caught and downgraded to
--   a WARNING inside the per-fleet subtransaction:
--
--       exception when others then
--         raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%', ...
--
--   A WARNING rolls nothing back and surfaces nothing, so the fleet stays 'RETURNING' and the next
--   heartbeat retries exactly the same doomed call. The fleet is stuck PERMANENTLY and the ships
--   (already debited from the origin when the mission was dispatched) are never returned.
--
--   Real reproduction, no artificial rewind needed -- only the ordinary event order:
--       started 9h ago . arrived 7h ago . hold expired 6h ago . outbound leg 2h
--       => returns_at = 6h ago + 2h = 4h AGO
--       The player meanwhile did anything on the origin planet (start_building, cancel_building,
--       load_fleet_cargo, the merchant, the UI's sync_current_planet_resources, or simply a later
--       heartbeat pass), which settles that planet to now().
--       Then the heartbeat drains the fleet: settlement to `returns_at` is refused forever.
--       Measured: origin 0 ships, movement stranded with 5 cruisers, status RETURNING, forever.
--
--   The sibling arrival resolvers shared the same trap; they are fixed in
--   20260930241000_fix_stuck_arrival_resolvers_past_event_timestamp.sql.
--
-- THE FIX
--   Clamp the settlement anchor to the planet's own clock: settle at
--   `greatest(returns_at, last_calculated_at)`.
--
--   This is not a weakening of the settlement guard: it still refuses to move the clock backwards for
--   any caller that passes a raw past timestamp; the worker simply stops ASKING for one. When the
--   event is already behind the clock there is no elapsed time left to credit, so settling at the
--   current clock is arithmetically correct: it grants zero extra production and it lets the return
--   finish. Nothing is invented and no balance changes.
--
-- NOT CHANGED: costs, times, travel, fuel, holding windows, combat, expedition rewards, the
-- settlement guard itself, or the canonical worker ordering (fleets before planets).

create or replace function public.process_fleet_movements()
returns table(fleet_id uuid, previous_status text, new_status text, processed_at timestamptz)
language plpgsql
set search_path to 'public', 'pg_temp'
as $fn$
DECLARE
  v record;
  v_duration interval;
  v_battle uuid;
  v_last_round integer;
  v_recycle record;
  v_new_status text;
  v_settle_at timestamptz;
BEGIN
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
    begin
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

        delete from public.fleet_movement_ships as fms where fms.fleet_id = v.id;

        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
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

    elsif v.mission_type in ('ATTACK','MOON_DESTRUCTION') then
      perform public.resolve_attack_arrival(v.id);

    elsif v.mission_type='MISSILE_ATTACK' then
      -- MISSILE SYSTEM: liquidacion propia y definitiva. El IPM no vuelve
      -- a su origen, asi que esta rama NO cae en el "else" de retorno.
      perform public.resolve_missile_attack_arrival(v.id);

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
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;
  end loop;

  for v in
    select fm.id,fm.status,fm.mission_type,fm.started_at,fm.arrives_at,fm.holding_until
    from public.fleet_movements fm
    where fm.status='HOLDING'
      and fm.holding_until<=clock_timestamp()
    order by fm.holding_until,fm.id
    for update skip locked
  loop
    begin
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
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;
  end loop;

  for v in
    select fm.id,fm.status,fm.mission_type,fm.returns_at
    from public.fleet_movements fm
    where fm.status='RETURNING'
      and fm.returns_at<=clock_timestamp()
    order by fm.returns_at,fm.id
    for update skip locked
  loop
    begin
      if v.mission_type='EXPEDITION' then
      perform public.resolve_expedition_return(v.id);
    end if;

    if v.mission_type<>'EXPEDITION'
       or exists(select 1 from public.fleet_movements where id=v.id and status='RETURNING')
    then
      if v.mission_type<>'EXPEDITION' then
        -- THE FIX (2026-09-30): anchor the settlement to the planet's own clock.
        -- The settlement guard correctly refuses to move a planet backwards, so a returns_at already
        -- behind last_calculated_at made this call fail forever (the per-fleet handler downgrades it
        -- to a WARNING), stranding the fleet in RETURNING with its ships already debited from the
        -- origin. greatest(returns_at, last_calculated_at) grants no extra production -- there is
        -- simply no elapsed time left to credit -- and lets the return complete.
        select greatest(v.returns_at, pr.last_calculated_at) into v_settle_at
        from public.planets p
        join public.planet_resources pr on pr.planet_id = p.id
        where p.id = (select fm.origin_planet_id from public.fleet_movements fm where fm.id = v.id);

        perform public.update_planet_resources_until(
          (select fm.origin_planet_id from public.fleet_movements fm where fm.id=v.id),
          coalesce(v_settle_at, v.returns_at)
        );
      end if;

      insert into public.planet_ships(planet_id, ship_id, quantity)
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
    exception
      when others then
        raise warning 'FLEET_RESOLUTION_FAILED fleet=% mission=% sqlstate=% error=%',
          v.id, v.mission_type, sqlstate, sqlerrm;
    end;
  end loop;
end;
$fn$;

-- Self-verifying: the clamp is present, the settlement guard is untouched, and the canonical
-- ordering (fleets before planets) survives.
do $post$
declare v_src text; v_guard text;
begin
  select p.prosrc into v_src from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='process_fleet_movements';

  if v_src not ilike '%greatest(v.returns_at, pr.last_calculated_at)%' then
    raise exception 'POSTCONDITION FAILED: the returns_at clamp is missing';
  end if;
  if v_src not ilike '%coalesce(v_settle_at, v.returns_at)%' then
    raise exception 'POSTCONDITION FAILED: settlement is not clamped';
  end if;

  select p.prosrc into v_guard from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='update_planet_resources_until_raw';
  if v_guard not ilike '%INVALID_RESOURCE_TIMESTAMP%' then
    raise exception 'POSTCONDITION FAILED: the settlement guard was weakened';
  end if;

  if (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='process_universe_tick')
     not ilike '%process_fleet_movements%' then
    raise exception 'POSTCONDITION FAILED: universe tick no longer drains fleets first';
  end if;
end $post$;