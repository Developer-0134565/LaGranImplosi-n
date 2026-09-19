-- Harden start_ship against unauthenticated guest bypass.
-- The owned-action contract requires auth.uid() to resolve to players.user_id.
-- No gameplay formula or queue semantics change.

create or replace function public.start_ship(
    p_player_id uuid,
    p_planet_id uuid,
    p_ship_id text,
    p_quantity bigint default 1
)
returns table(
    queue_id uuid,
    ship_id text,
    quantity bigint,
    started_at timestamptz,
    finishes_at timestamptz,
    metal_cost numeric,
    crystal_cost numeric,
    deuterium_cost numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_planet_player uuid;
    v_reason text;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
    v_metal_available numeric;
    v_crystal_available numeric;
    v_deuterium_available numeric;
    v_unit_time numeric;
    v_total_time numeric;
    v_started_at timestamptz;
    v_finishes_at timestamptz;
    v_queue_id uuid;
    v_auth_user uuid := auth.uid();
begin
    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    if not exists (
        select 1
        from public.players pl
        where pl.id = p_player_id
          and pl.user_id = v_auth_user
    ) then
        raise exception 'Player does not belong to authenticated user';
    end if;

    if p_quantity <= 0 then
        raise exception 'Quantity must be greater than 0';
    end if;

    select p.player_id
      into v_planet_player
    from public.planets p
    where p.id = p_planet_id
      and not p.is_destroyed
    for update;

    if not found then
        raise exception 'Planet not found or destroyed';
    end if;

    if v_planet_player <> p_player_id then
        raise exception 'Planet does not belong to player';
    end if;

    if not exists (
        select 1 from public.ship_definitions sd where sd.id = p_ship_id
    ) then
        raise exception 'Unknown ship: %', p_ship_id;
    end if;

    perform public.process_planet_tick(p_planet_id);

    select r.reason
      into v_reason
    from public.check_ship_requirements(p_planet_id, p_ship_id) r
    where not r.allowed
    limit 1;

    if v_reason is not null then
        raise exception '%', v_reason;
    end if;

    select c.metal, c.crystal, c.deuterium
      into v_metal, v_crystal, v_deuterium
    from public.calculate_ship_cost(p_ship_id, p_quantity) c;

    select pr.metal, pr.crystal, pr.deuterium
      into v_metal_available, v_crystal_available, v_deuterium_available
    from public.planet_resources pr
    where pr.planet_id = p_planet_id
    for update;

    if not found then
        raise exception 'Planet resources not found';
    end if;

    if v_metal_available < v_metal then raise exception 'Not enough metal'; end if;
    if v_crystal_available < v_crystal then raise exception 'Not enough crystal'; end if;
    if v_deuterium_available < v_deuterium then raise exception 'Not enough deuterium'; end if;

    v_unit_time := public.calculate_ship_build_time(p_planet_id, p_ship_id);
    v_total_time := v_unit_time * p_quantity;

    select greatest(
        coalesce((
            select max(sq.finishes_at)
            from public.shipyard_queue sq
            where sq.planet_id = p_planet_id
              and sq.status = 'BUILDING'
              and sq.finishes_at > now()
        ), now()),
        coalesce((
            select max(dq.finishes_at)
            from public.defense_queue dq
            where dq.planet_id = p_planet_id
              and dq.status = 'BUILDING'
              and dq.finishes_at > now()
        ), now())
    )
      into v_started_at;

    v_finishes_at := v_started_at + make_interval(secs => v_total_time);

    update public.planet_resources
       set metal = metal - v_metal,
           crystal = crystal - v_crystal,
           deuterium = deuterium - v_deuterium,
           updated_at = now()
     where planet_id = p_planet_id;

    insert into public.shipyard_queue(
        planet_id, ship_id, quantity, started_at, finishes_at, status
    )
    values(
        p_planet_id, p_ship_id, p_quantity, v_started_at, v_finishes_at, 'BUILDING'
    )
    returning id into v_queue_id;

    return query
    select v_queue_id, p_ship_id, p_quantity, v_started_at, v_finishes_at,
           v_metal, v_crystal, v_deuterium;
end;
$function$;

revoke execute on function public.start_ship(uuid, uuid, text, bigint)
from anon;

grant execute on function public.start_ship(uuid, uuid, text, bigint)
to authenticated;
