create or replace function public.start_research(p_player_id uuid, p_planet_id uuid, p_research_id text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_universe_id uuid;
    v_current_level integer;
    v_target_level integer;
    v_research_time numeric;
    v_metal_cost numeric;
    v_crystal_cost numeric;
    v_deuterium_cost numeric;
    v_queue_id uuid;
    v_item_bonus numeric := 0;
    v_auth_user uuid;
begin
    v_auth_user := auth.uid();

    if v_auth_user is not null and not exists (
        select 1 from public.players pl
        where pl.id = p_player_id
          and pl.user_id = v_auth_user
    ) then
        raise exception 'Player does not belong to authenticated user';
    end if;

    if v_auth_user is null and not exists (
        select 1 from public.players pl
        where pl.id = p_player_id
          and coalesce(pl.is_guest, false) = true
    ) then
        raise exception 'Authentication required';
    end if;

    -- Research is player-wide, not planet-wide. Lock the player row so two
    -- simultaneous requests cannot both pass the single research-queue check.
    perform 1 from public.players where id = p_player_id for update;

    select universe_id into v_universe_id
    from public.planets
    where id = p_planet_id and player_id = p_player_id and is_destroyed = false
    for update;

    if v_universe_id is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    if not exists(select 1 from public.research_definitions where id=p_research_id) then
        raise exception 'RESEARCH_NOT_FOUND: %',p_research_id;
    end if;

    select coalesce(max(level),0) into v_current_level
    from public.player_research
    where player_id=p_player_id and research_id=p_research_id;
    v_target_level:=v_current_level+1;

    if exists(
        select 1 from public.research_definitions
        where id=p_research_id and max_level is not null and v_target_level>max_level
    ) then
        raise exception 'RESEARCH_MAX_LEVEL_REACHED';
    end if;

    -- Authoritative prerequisite validation. The old start path checked the
    -- definition, max level and queue, but could bypass research_prerequisites.
    if not public.can_research(p_player_id, p_research_id, v_target_level) then
        raise exception 'RESEARCH_REQUIREMENTS_NOT_MET';
    end if;

    if exists(
        select 1 from public.research_queue
        where player_id=p_player_id
          and upper(status) in('RESEARCHING','QUEUED','ACTIVE')
    ) then
        raise exception 'RESEARCH_QUEUE_ALREADY_ACTIVE';
    end if;

    select c.metal,c.crystal,c.deuterium into v_metal_cost,v_crystal_cost,v_deuterium_cost
    from public.calculate_research_cost(p_research_id,v_target_level) c;

    v_research_time:=public.calculate_research_time(p_research_id,v_target_level,v_universe_id);
    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);

    perform public.process_planet_tick(p_planet_id);
    perform 1 from public.planet_resources where planet_id=p_planet_id for update;

    update public.planet_resources
    set metal=metal-v_metal_cost,
        crystal=crystal-v_crystal_cost,
        deuterium=deuterium-v_deuterium_cost,
        updated_at=now()
    where planet_id=p_planet_id
      and metal>=v_metal_cost
      and crystal>=v_crystal_cost
      and deuterium>=v_deuterium_cost;

    if not found then
        raise exception 'INSUFFICIENT_RESOURCES';
    end if;

    insert into public.research_queue(
        player_id,planet_id,research_id,target_level,started_at,finishes_at,status
    )
    values(
        p_player_id,p_planet_id,p_research_id,v_target_level,now(),
        now()+(v_research_time*interval '1 second'),'RESEARCHING'
    )
    returning id into v_queue_id;

    return v_queue_id;
end;
$function$;