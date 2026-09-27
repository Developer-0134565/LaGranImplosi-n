-- BUILDING / RESEARCH CANCELLATION — forward-only fix for the `planet_id` ambiguity.
-- --------------------------------------------------------------------------------------------
-- `20260926082120_cancel_building_and_research_queue_contract` deployed both cancellation RPCs with an
-- OUT parameter named `planet_id`. Inside PL/pgSQL that name shadows the table column, so
--         update public.planet_resources set ... where planet_id = v_queue.planet_id;
-- raised 42702 "column reference planet_id is ambiguous" on EVERY call (the RETURNS TABLE column list
-- makes the OUT parameter visible in the function body). Detected by the new fixture
-- `supabase/tests/queue_cancellation.sql` before any live use; the same defect class as the previously
-- fixed `fleet_id` ambiguities (`20260925172115`, `20260925172311`).
--
-- No behaviour, signature, return shape, refund policy or ACL changes: only the DML identifiers are now
-- alias-qualified (`pr.planet_id`, `bq.id`, `rq.id`) so no OUT-parameter name can shadow a column again.
-- The migration that introduced the defect keeps its original content (provenance gate).

create or replace function public.cancel_building(p_queue_id uuid)
returns table(
    queue_id uuid,
    planet_id uuid,
    building_id text,
    target_level integer,
    refund_metal numeric,
    refund_crystal numeric,
    refund_deuterium numeric,
    status text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_queue public.building_queue%rowtype;
    v_owner uuid;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
begin
    v_auth_user := auth.uid();
    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    select bq.* into v_queue
    from public.building_queue bq
    where bq.id = p_queue_id
    for update;

    if not found then
        raise exception 'BUILDING_QUEUE_NOT_FOUND: %', p_queue_id;
    end if;

    select pl.id into v_owner
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where p.id = v_queue.planet_id
      and pl.user_id = v_auth_user;

    if v_owner is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    if upper(v_queue.status) = 'COMPLETED' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: COMPLETED';
    end if;

    if upper(v_queue.status) <> 'BUILDING' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    perform * from public.process_planet_tick(v_queue.planet_id);

    select bq.* into v_queue
    from public.building_queue bq
    where bq.id = p_queue_id
    for update;

    if upper(v_queue.status) <> 'BUILDING' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    select c.metal, c.crystal, c.deuterium
    into v_metal, v_crystal, v_deuterium
    from public.calculate_building_cost(v_queue.building_id, v_queue.target_level) c;

    perform 1 from public.planet_resources pr where pr.planet_id = v_queue.planet_id for update;
    if not found then
        raise exception 'PLANET_RESOURCES_NOT_FOUND';
    end if;

    update public.planet_resources pr
       set metal = pr.metal + v_metal,
           crystal = pr.crystal + v_crystal,
           deuterium = pr.deuterium + v_deuterium,
           updated_at = now()
     where pr.planet_id = v_queue.planet_id;

    update public.building_queue bq
       set status = 'CANCELLED'
     where bq.id = p_queue_id;

    return query
    select v_queue.id, v_queue.planet_id, v_queue.building_id, v_queue.target_level,
           v_metal, v_crystal, v_deuterium, 'CANCELLED'::text;
end;
$function$;

create or replace function public.cancel_research(p_queue_id uuid)
returns table(
    queue_id uuid,
    player_id uuid,
    planet_id uuid,
    research_id text,
    target_level integer,
    refund_metal numeric,
    refund_crystal numeric,
    refund_deuterium numeric,
    status text
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_queue public.research_queue%rowtype;
    v_owner uuid;
    v_metal numeric;
    v_crystal numeric;
    v_deuterium numeric;
begin
    v_auth_user := auth.uid();
    if v_auth_user is null then
        raise exception 'Authentication required';
    end if;

    select rq.* into v_queue
    from public.research_queue rq
    where rq.id = p_queue_id
    for update;

    if not found then
        raise exception 'RESEARCH_QUEUE_NOT_FOUND: %', p_queue_id;
    end if;

    select pl.id into v_owner
    from public.players pl
    where pl.id = v_queue.player_id
      and pl.user_id = v_auth_user;

    if v_owner is null then
        raise exception 'PLAYER_NOT_OWNED';
    end if;

    if v_queue.planet_id is null then
        raise exception 'RESEARCH_QUEUE_REFUND_PLANET_UNKNOWN';
    end if;

    perform 1 from public.planets p
     where p.id = v_queue.planet_id
       and p.player_id = v_owner
       and p.is_destroyed = false;
    if not found then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    if upper(v_queue.status) = 'COMPLETED' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: COMPLETED';
    end if;

    if upper(v_queue.status) <> 'RESEARCHING' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    perform * from public.process_planet_tick(v_queue.planet_id);

    select rq.* into v_queue
    from public.research_queue rq
    where rq.id = p_queue_id
    for update;

    if upper(v_queue.status) <> 'RESEARCHING' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    select c.metal, c.crystal, c.deuterium
    into v_metal, v_crystal, v_deuterium
    from public.calculate_research_cost(v_queue.research_id, v_queue.target_level) c;

    perform 1 from public.planet_resources pr where pr.planet_id = v_queue.planet_id for update;
    if not found then
        raise exception 'PLANET_RESOURCES_NOT_FOUND';
    end if;

    update public.planet_resources pr
       set metal = pr.metal + v_metal,
           crystal = pr.crystal + v_crystal,
           deuterium = pr.deuterium + v_deuterium,
           updated_at = now()
     where pr.planet_id = v_queue.planet_id;

    update public.research_queue rq
       set status = 'CANCELLED'
     where rq.id = p_queue_id;

    return query
    select v_queue.id, v_queue.player_id, v_queue.planet_id, v_queue.research_id, v_queue.target_level,
           v_metal, v_crystal, v_deuterium, 'CANCELLED'::text;
end;
$function$;

comment on function public.cancel_building(uuid) is
$c$Cancels the single active building-queue item of an OWNED planet and refunds 100 % of the price that was
charged (recomputed with calculate_building_cost at the row's target_level). OGameX parity:
BuildingQueueService::cancel() refunds exactly the stored price of an already-started item, with no penalty.
Ownership is derived from auth.uid() → players.user_id → planets.player_id. Rejections (foreign planet,
COMPLETED/CANCELLED row, already-due item completed by the tick) raise before mutating anything.
Certified by supabase/tests/queue_cancellation.sql; DML identifiers alias-qualified to avoid the OUT-parameter
ambiguity that the introducing migration carried.$c$;

comment on function public.cancel_research(uuid) is
$c$Cancels the single active research-queue item of the authenticated owner and refunds 100 % of the price
that was charged (recomputed with calculate_research_cost at the row's target_level), credited to the planet
that started the research (research_queue.planet_id). OGameX parity: the queue services cancel the row and
refund exactly the stored price; no penalty and no Dark Matter. Ownership is derived from
auth.uid() → players.user_id. A row without a planet, or a COMPLETED/CANCELLED row, is refused before
mutating anything. Certified by supabase/tests/queue_cancellation.sql; DML identifiers alias-qualified to
avoid the OUT-parameter ambiguity that the introducing migration carried.$c$;

revoke all on function public.cancel_building(uuid) from public;
revoke all on function public.cancel_building(uuid) from anon;
grant execute on function public.cancel_building(uuid) to authenticated;
grant execute on function public.cancel_building(uuid) to service_role;

revoke all on function public.cancel_research(uuid) from public;
revoke all on function public.cancel_research(uuid) from anon;
grant execute on function public.cancel_research(uuid) to authenticated;
grant execute on function public.cancel_research(uuid) to service_role;

