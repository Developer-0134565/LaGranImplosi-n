-- BUILDING / RESEARCH QUEUE CANCELLATION — LA GRAN IMPLOSIÓN
-- --------------------------------------------------------------------------------------------
-- Closes the documented gap "queues admit CANCELLED and NO function ever writes it" for the two queues where
-- OGameX HAS a cancellation mechanic, with the refund policy taken from OGameX instead of invented.
--
-- OGameX evidence (`BuildingQueueService.php`, commit 7c420bad3478d7099791e1f33c920e9ff92822e8, read-only):
--   * `cancel()` refunds EXACTLY the price stored on the cancelled queue row, and only when the item had
--     already started (therefore already charged):
--         if ($queue_item->building === 1) {
--             $planet->addResources(new Resources($queue_item->metal, $queue_item->crystal, $queue_item->deuterium, 0));
--         }
--     → 100 % of the charged price, no penalty, no partial salvage, no Dark Matter involved.
--   * the row is flagged, never deleted: `$queue_item->canceled = 1; $queue_item->building = 0;`
--   * cancelling cascades to queue items whose requirements are no longer met
--     (`cancelItemMissingRequirements`) and to research items with broken requirements. LGI holds ONE active
--     item per queue and validates prerequisites at start time, so there is nothing to cascade here.
--   * `UnitQueueService.php` states verbatim that "unit queue objects cannot be canceled" → the shipyard and
--     defence queues keep NO cancellation path in LGI. That is OGameX parity, not a missing contract.
--
-- LGI adaptation (no new price model, no new status, no schema change):
--   * LGI deducts the price at start_* time and stores no price column, so the refund is RECOMPUTED with the
--     same certified cost function the charge used (`calculate_building_cost` / `calculate_research_cost` at
--     the row's stored `target_level`). refund == charge by construction, for every level.
--   * resources are settled first through the authoritative tick (`process_planet_tick`), so a row that is
--     already due is COMPLETED by the normal path and can never be refunded AND granted (no double credit).
--   * the refund is credited with the same "add and let the global storage rule apply" convention already
--     used by fleet-cargo delivery (`20260925171816`); no new capacity rule is introduced.
--   * ownership is derived exclusively from `auth.uid()` → `players.user_id` → `planets.player_id`. No
--     client-supplied player/planet id is accepted, and no first-player / guest heuristic exists.
--   * atomicity: refund + status change happen inside one SECURITY DEFINER function (one transaction). A
--     rejected call raises before touching resources, so a retry can never duplicate or double-refund.
--
-- Certified by `supabase/tests/queue_cancellation.sql`.

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

    select * into v_queue
    from public.building_queue bq
    where bq.id = p_queue_id
    for update;

    if not found then
        raise exception 'BUILDING_QUEUE_NOT_FOUND: %', p_queue_id;
    end if;

    /* Ownership: planet → players.user_id, never a client-supplied identity. */
    select pl.id into v_owner
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where p.id = v_queue.planet_id
      and pl.user_id = v_auth_user;

    if v_owner is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    /* COMPLETED is terminal: the level was granted and nothing is refunded. */
    if upper(v_queue.status) = 'COMPLETED' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: COMPLETED';
    end if;

    if upper(v_queue.status) <> 'BUILDING' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    /* Authoritative settlement: a due item completes here and stops being cancellable. */
    perform * from public.process_planet_tick(v_queue.planet_id);

    select * into v_queue
    from public.building_queue bq
    where bq.id = p_queue_id
    for update;

    if upper(v_queue.status) <> 'BUILDING' then
        raise exception 'BUILDING_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    /* Refund = the exact price the start path charged for this target level. */
    select c.metal, c.crystal, c.deuterium
    into v_metal, v_crystal, v_deuterium
    from public.calculate_building_cost(v_queue.building_id, v_queue.target_level) c;

    perform 1 from public.planet_resources pr where pr.planet_id = v_queue.planet_id for update;
    if not found then
        raise exception 'PLANET_RESOURCES_NOT_FOUND';
    end if;

    update public.planet_resources
       set metal = metal + v_metal,
           crystal = crystal + v_crystal,
           deuterium = deuterium + v_deuterium,
           updated_at = now()
     where planet_id = v_queue.planet_id;

    update public.building_queue
       set status = 'CANCELLED'
     where id = p_queue_id;

    return query
    select v_queue.id, v_queue.planet_id, v_queue.building_id, v_queue.target_level,
           v_metal, v_crystal, v_deuterium, 'CANCELLED'::text;
end;
$function$;

comment on function public.cancel_building(uuid) is
$c$Cancels the single active building-queue item of an OWNED planet and refunds 100 % of the price that was
charged (recomputed with calculate_building_cost at the row's target_level). OGameX parity:
BuildingQueueService::cancel() refunds exactly the stored price of an already-started item, with no penalty.
Ownership is derived from auth.uid() → players.user_id → planets.player_id. Rejected calls (foreign planet,
COMPLETED/CANCELLED row, already-due item completed by the tick) raise before mutating anything.
Certified by supabase/tests/queue_cancellation.sql.$c$;

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

    select * into v_queue
    from public.research_queue rq
    where rq.id = p_queue_id
    for update;

    if not found then
        raise exception 'RESEARCH_QUEUE_NOT_FOUND: %', p_queue_id;
    end if;

    /* Ownership of the research row: players.user_id = auth.uid(). */
    select pl.id into v_owner
    from public.players pl
    where pl.id = v_queue.player_id
      and pl.user_id = v_auth_user;

    if v_owner is null then
        raise exception 'PLAYER_NOT_OWNED';
    end if;

    /* The research was charged to the planet that started it (research_queue.planet_id). A row without a
       refund planet cannot be refunded deterministically, so it is refused instead of guessing one. */
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

    /* COMPLETED is terminal: the level was granted and nothing is refunded. */
    if upper(v_queue.status) = 'COMPLETED' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: COMPLETED';
    end if;

    if upper(v_queue.status) <> 'RESEARCHING' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    /* Authoritative settlement: a due research completes here and stops being cancellable. */
    perform * from public.process_planet_tick(v_queue.planet_id);

    select * into v_queue
    from public.research_queue rq
    where rq.id = p_queue_id
    for update;

    if upper(v_queue.status) <> 'RESEARCHING' then
        raise exception 'RESEARCH_QUEUE_NOT_CANCELLABLE: %', v_queue.status;
    end if;

    /* Refund = the exact price the start path charged for this target level. */
    select c.metal, c.crystal, c.deuterium
    into v_metal, v_crystal, v_deuterium
    from public.calculate_research_cost(v_queue.research_id, v_queue.target_level) c;

    perform 1 from public.planet_resources pr where pr.planet_id = v_queue.planet_id for update;
    if not found then
        raise exception 'PLANET_RESOURCES_NOT_FOUND';
    end if;

    update public.planet_resources
       set metal = metal + v_metal,
           crystal = crystal + v_crystal,
           deuterium = deuterium + v_deuterium,
           updated_at = now()
     where planet_id = v_queue.planet_id;

    update public.research_queue
       set status = 'CANCELLED'
     where id = p_queue_id;

    return query
    select v_queue.id, v_queue.player_id, v_queue.planet_id, v_queue.research_id, v_queue.target_level,
           v_metal, v_crystal, v_deuterium, 'CANCELLED'::text;
end;
$function$;

comment on function public.cancel_research(uuid) is
$c$Cancels the single active research-queue item of the authenticated owner and refunds 100 % of the price that
was charged (recomputed with calculate_research_cost at the row's target_level), credited to the planet that
started the research (research_queue.planet_id). OGameX parity: the queue services cancel the row and refund
exactly the stored price; no penalty and no Dark Matter. Ownership is derived from auth.uid() →
players.user_id. A row without a planet, or a COMPLETED/CANCELLED row, is refused before mutating anything.
Certified by supabase/tests/queue_cancellation.sql.$c$;

revoke all on function public.cancel_building(uuid) from public;
revoke all on function public.cancel_building(uuid) from anon;
grant execute on function public.cancel_building(uuid) to authenticated;
grant execute on function public.cancel_building(uuid) to service_role;

revoke all on function public.cancel_research(uuid) from public;
revoke all on function public.cancel_research(uuid) from anon;
grant execute on function public.cancel_research(uuid) to authenticated;
grant execute on function public.cancel_research(uuid) to service_role;

