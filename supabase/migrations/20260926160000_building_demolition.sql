-- =====================================================================
-- BUILDING DEMOLITION (DOWNGRADE) — LGI ↔ OGameX PARITY
-- =====================================================================
-- OGameX reference (structural):
--   app/Services/BuildingQueueService.php :: addDowngrade() / start()
--   app/Services/ObjectService.php        :: getObjectDowngradePrice() / canDowngradeBuilding()
--   app/Services/PlanetService.php        :: getBuildingDowngradeTime()
--
-- Adopted rules (OGameX):
--   1. Only buildings can be downgraded, one level per queue item, never below level 0.
--   2. Demolishing COSTS resources: the construction price of the level being removed,
--      reduced by 4 % per ion_technology level (floor per resource, never negative).
--   3. Duration is the construction formula evaluated at the level being removed
--      (OGameX: "same formula as construction time but for level instead of next_level").
--   4. A level can not be removed while another present building still depends on it
--      (OGameX canDowngradeBuilding).
--   5. A level can not be removed while an active research depends on it
--      (OGameX: research_lab guard while research is in progress).
--   6. A level can not be removed while an active ship/defense order depends on it
--      (OGameX: shipyard guard while ships/defense are being built).
--   7. The queue item is flagged is_downgrade (OGameX building_queue.is_downgrade).
--   8. Cancelling a demolition refunds exactly what was charged.
--
-- LGI adaptations (documented, not invented):
--   * LGI queues at most one building item per planet, so OGameX "level_after_queue" is
--     always the current level and the target is current_level - 1.
--   * OGameX hardcodes research_lab / missile_silo / terraformer guards; LGI has none of
--     those objects, so rules 5 and 6 are data-driven from research_building_prerequisites
--     and ship_prerequisites / defense_prerequisites.
--   * fields_used mirrors the certified "+1 per completed level" with "-1 per demolished level".
--   * A fully demolished building keeps its planet_buildings row at level 0: every reader uses
--     COALESCE/MAX(level) so level 0 equals absent, and keeping the row as an UPDATE keeps
--     trg_sync_moon_field_capacity firing (a DELETE would silently skip the moon re-sync).
-- =====================================================================

alter table public.building_queue
    add column if not exists is_downgrade boolean not null default false;

comment on column public.building_queue.is_downgrade is
    'OGameX building_queue.is_downgrade: this item demolishes one level instead of building one.';

alter table public.building_queue drop constraint if exists building_queue_target_level_check;
alter table public.building_queue
    add constraint building_queue_target_level_check check (target_level >= 0);

-- ---------------------------------------------------------------------
-- OGameX ObjectService::getObjectDowngradePrice()
-- ---------------------------------------------------------------------
create or replace function public.calculate_building_demolition_cost(
    p_building_id text,
    p_level integer,
    p_ion_technology_level integer
)
returns table(metal numeric, crystal numeric, deuterium numeric)
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_base_metal numeric;
    v_base_crystal numeric;
    v_base_deuterium numeric;
    v_factor numeric;
begin
    if p_level is null or p_level < 1 then
        raise exception 'DEMOLITION_LEVEL_ZERO: the level to demolish must be >= 1';
    end if;

    select c.metal, c.crystal, c.deuterium
    into v_base_metal, v_base_crystal, v_base_deuterium
    from public.calculate_building_cost(p_building_id, p_level) c;

    /* OGameX: each ion technology level reduces the demolition price by 4 %. */
    v_factor := greatest(0::numeric, 1 - (coalesce(p_ion_technology_level, 0) * 0.04));

    return query select
        greatest(0::numeric, floor(coalesce(v_base_metal, 0) * v_factor)),
        greatest(0::numeric, floor(coalesce(v_base_crystal, 0) * v_factor)),
        greatest(0::numeric, floor(coalesce(v_base_deuterium, 0) * v_factor));
end;
$function$;

-- ---------------------------------------------------------------------
-- Single demolition authority: every side condition, cost, duration and reason code.
-- SECURITY DEFINER because it IS the ownership gate (it resolves the caller from auth.uid()
-- before reading anything else and never returns another player's data); both the client
-- contract can_start_demolition and the mutating start_demolition consume it, so preview and
-- execution can not drift apart.
-- ---------------------------------------------------------------------
create or replace function public.inspect_demolition(
    p_player_id uuid,
    p_planet_id uuid,
    p_building_id text
)
returns table(
    allowed boolean,
    reason text,
    current_level integer,
    target_level integer,
    ion_technology_level integer,
    cost_metal numeric,
    cost_crystal numeric,
    cost_deuterium numeric,
    duration_seconds numeric,
    available_metal numeric,
    available_crystal numeric,
    available_deuterium numeric,
    dependents_met boolean,
    research_idle boolean,
    unit_queue_idle boolean,
    queue_available boolean,
    is_downgrade boolean
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
    v_universe_id uuid;
    v_current_level integer := 0;
    v_target_level integer := 0;
    v_ion integer := 0;
    v_item_bonus numeric := 0;
    v_metal numeric := 0;
    v_crystal numeric := 0;
    v_deuterium numeric := 0;
    v_time numeric := 0;
    v_avail_metal numeric := 0;
    v_avail_crystal numeric := 0;
    v_avail_deuterium numeric := 0;
    v_dependents boolean := false;
    v_research_idle boolean := false;
    v_unit_queue_idle boolean := false;
    v_queue_available boolean := false;
    v_reason text;
begin
    /* 1. IDENTITY — owner session or the certified AI service actor (never a trusted client id). */
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        v_reason := 'PLAYER_NOT_OWNED_BY_AUTH_USER';
    elsif v_auth_user is null and not public.is_ai_actor_target(p_player_id) then
        v_reason := 'AUTHENTICATION_REQUIRED';
    end if;

    /* 2. OWNERSHIP — the planet must belong to that player. */
    if v_reason is null then
        select p.universe_id into v_universe_id
        from public.planets p
        where p.id = p_planet_id and p.player_id = p_player_id and p.is_destroyed = false;

        if v_universe_id is null then
            v_reason := 'PLANET_NOT_FOUND_OR_NOT_OWNED';
        end if;
    end if;

    if v_reason is null then
        select coalesce(max(pb.level), 0) into v_current_level
        from public.planet_buildings pb
        where pb.planet_id = p_planet_id and pb.building_id = p_building_id;

        if not exists (select 1 from public.building_definitions bd where bd.id = p_building_id) then
            v_reason := 'BUILDING_NOT_FOUND';
        elsif v_current_level < 1 then
            v_reason := 'DEMOLITION_LEVEL_ZERO';
        end if;
    end if;

    if v_reason is null then
        v_target_level := v_current_level - 1;
        v_ion := coalesce(public.get_player_research_level(p_player_id, 'ion_technology'), 0);

        select c.metal, c.crystal, c.deuterium
        into v_metal, v_crystal, v_deuterium
        from public.calculate_building_demolition_cost(p_building_id, v_current_level, v_ion) c;

        /* OGameX PlanetService::getBuildingDowngradeTime(): construction formula at the removed level. */
        v_time := public.calculate_building_time(p_building_id, v_current_level, v_universe_id);
        v_item_bonus := coalesce(public.get_active_expedition_item_effect(p_player_id, p_planet_id, 'building_speed_percent'), 0);
        /* OGameX: "Minimum time is always 1 second for all objects/units." */
        v_time := greatest(1, round(v_time / (1 + v_item_bonus / 100), 4));

        select pr.metal, pr.crystal, pr.deuterium
        into v_avail_metal, v_avail_crystal, v_avail_deuterium
        from public.planet_resources pr
        where pr.planet_id = p_planet_id;

        v_queue_available := not exists (
            select 1 from public.building_queue bq
            where bq.planet_id = p_planet_id and upper(bq.status) in ('BUILDING', 'QUEUED', 'ACTIVE')
        );

        /* Rule 4: a present building that still needs the level being removed. */
        v_dependents := not exists (
            select 1
            from public.building_prerequisites bp
            join public.planet_buildings dep
              on dep.planet_id = p_planet_id
             and dep.building_id = bp.building_id
             and dep.level > 0
            where bp.prerequisite_building_id = p_building_id
              and bp.required_level > v_target_level
        );

        /* Rule 5: an active research that still needs the level being removed. */
        v_research_idle := not exists (
            select 1
            from public.research_queue rq
            join public.research_building_prerequisites rbp on rbp.research_id = rq.research_id
            where rq.player_id = p_player_id
              and upper(rq.status) = 'RESEARCHING'
              and rbp.building_id = p_building_id
              and rbp.required_level > v_target_level
        );

        /* Rule 6: an active ship/defense order that still needs the level being removed. */
        v_unit_queue_idle := not (
            exists (
                select 1
                from public.shipyard_queue sq
                join public.ship_prerequisites sp
                  on sp.ship_id = sq.ship_id and sp.prerequisite_type = 'building'
                where sq.planet_id = p_planet_id
                  and upper(sq.status) = 'BUILDING'
                  and sp.building_id = p_building_id
                  and sp.required_level > v_target_level
            )
            or exists (
                select 1
                from public.defense_queue dq
                join public.defense_prerequisites dp
                  on dp.defense_id = dq.defense_id and dp.prerequisite_type = 'building'
                where dq.planet_id = p_planet_id
                  and upper(dq.status) = 'BUILDING'
                  and dp.building_id = p_building_id
                  and dp.required_level > v_target_level
            )
        );

        v_reason := case
            when not v_queue_available then 'BUILDING_QUEUE_ALREADY_ACTIVE'
            when not v_dependents then 'DEMOLITION_BLOCKED_BY_DEPENDENTS'
            when not v_research_idle then 'DEMOLITION_BLOCKED_BY_ACTIVE_RESEARCH'
            when not v_unit_queue_idle then 'DEMOLITION_BLOCKED_BY_ACTIVE_UNIT_QUEUE'
            when v_avail_metal < v_metal or v_avail_crystal < v_crystal or v_avail_deuterium < v_deuterium
                then 'INSUFFICIENT_RESOURCES'
            else 'OK'
        end;
    end if;

    return query select
        (v_reason = 'OK'),
        v_reason,
        v_current_level,
        v_target_level,
        v_ion,
        v_metal,
        v_crystal,
        v_deuterium,
        v_time,
        v_avail_metal,
        v_avail_crystal,
        v_avail_deuterium,
        v_dependents,
        v_research_idle,
        v_unit_queue_idle,
        v_queue_available,
        true;
end;
$function$;

-- ---------------------------------------------------------------------
-- Client preview contract (mirror of can_start_building; no anon grant).
-- ---------------------------------------------------------------------
create or replace function public.can_start_demolition(
    p_player_id uuid,
    p_planet_id uuid,
    p_building_id text
)
returns table(
    allowed boolean,
    reason text,
    current_level integer,
    target_level integer,
    ion_technology_level integer,
    cost_metal numeric,
    cost_crystal numeric,
    cost_deuterium numeric,
    duration_seconds numeric,
    available_metal numeric,
    available_crystal numeric,
    available_deuterium numeric,
    dependents_met boolean,
    research_idle boolean,
    unit_queue_idle boolean,
    queue_available boolean,
    is_downgrade boolean
)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    select i.allowed, i.reason, i.current_level, i.target_level, i.ion_technology_level,
           i.cost_metal, i.cost_crystal, i.cost_deuterium, i.duration_seconds,
           i.available_metal, i.available_crystal, i.available_deuterium,
           i.dependents_met, i.research_idle, i.unit_queue_idle, i.queue_available, i.is_downgrade
    from public.inspect_demolition(p_player_id, p_planet_id, p_building_id) i;
$function$;

-- ---------------------------------------------------------------------
-- Mutating contract. It consumes the single authority above and raises its reason code
-- verbatim, so clients branch on stable codes (LGI error-code convention).
-- ---------------------------------------------------------------------
create or replace function public.start_demolition(
    p_player_id uuid,
    p_planet_id uuid,
    p_building_id text
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_universe_id uuid;
    v_inspect record;
    v_queue_id uuid;
begin
    /* Lock the planet first so two concurrent demolition requests serialise on it. */
    select p.universe_id into v_universe_id
    from public.planets p
    where p.id = p_planet_id and p.player_id = p_player_id and p.is_destroyed = false
    for update;

    if v_universe_id is null then
        raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    end if;

    select * into v_inspect
    from public.inspect_demolition(p_player_id, p_planet_id, p_building_id);

    if not coalesce(v_inspect.allowed, false) then
        raise exception '%', coalesce(v_inspect.reason, 'DEMOLITION_NOT_ALLOWED');
    end if;

    perform public.process_planet_tick(p_planet_id);
    perform 1 from public.planet_resources where planet_id = p_planet_id for update;

    update public.planet_resources
       set metal = metal - v_inspect.cost_metal,
           crystal = crystal - v_inspect.cost_crystal,
           deuterium = deuterium - v_inspect.cost_deuterium,
           updated_at = now()
     where planet_id = p_planet_id
       and metal >= v_inspect.cost_metal
       and crystal >= v_inspect.cost_crystal
       and deuterium >= v_inspect.cost_deuterium;

    if not found then
        raise exception 'INSUFFICIENT_RESOURCES';
    end if;

    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (p_planet_id, p_building_id, v_inspect.target_level, now(),
            now() + (v_inspect.duration_seconds * interval '1 second'), 'BUILDING', true)
    returning id into v_queue_id;

    return v_queue_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- CERTIFIED-CONTRACT PATCH 1/2 — complete_building() learns the downgrade case.
-- Contract preserved: an upgrade still requires target = current + 1, still writes
-- fields_used + 1, still returns the target level and stays idempotent on COMPLETED.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'complete_building';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: complete_building';
    end if;

    if position('is_downgrade' in v_src) > 0 then
        return; /* already patched */
    end if;

    v_old := '    IF v_queue.target_level <> v_current_level + 1 THEN
        RAISE EXCEPTION ''BUILDING_LEVEL_MISMATCH: current=%, target=%'', v_current_level, v_queue.target_level;
    END IF;';

    v_new := '    IF coalesce(v_queue.is_downgrade, false) THEN
        /* DEMOLITION: OGameX BuildingQueueService::start() keeps the target at current_level - 1. */
        IF v_queue.target_level <> v_current_level - 1 THEN
            RAISE EXCEPTION ''BUILDING_LEVEL_MISMATCH: current=%, target=%'', v_current_level, v_queue.target_level;
        END IF;
    ELSE
        IF v_queue.target_level <> v_current_level + 1 THEN
            RAISE EXCEPTION ''BUILDING_LEVEL_MISMATCH: current=%, target=%'', v_current_level, v_queue.target_level;
        END IF;
    END IF;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: complete_building level check';
    end if;
    v_src := replace(v_src, v_old, v_new);

    v_old := '    UPDATE public.planets SET fields_used = fields_used + 1 WHERE id = v_queue.planet_id;';

    v_new := '    IF coalesce(v_queue.is_downgrade, false) THEN
        /* A demolished level releases a field (mirror of the certified +1 per level). The
           planet_buildings row is kept at level 0 - every reader aggregates with
           COALESCE/MAX(level) - because the UPDATE keeps trg_sync_moon_field_capacity firing. */
        UPDATE public.planets SET fields_used = greatest(0, fields_used - 1) WHERE id = v_queue.planet_id;
    ELSE
        UPDATE public.planets SET fields_used = fields_used + 1 WHERE id = v_queue.planet_id;
    END IF;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: complete_building fields_used update';
    end if;
    v_src := replace(v_src, v_old, v_new);

    execute v_src;
end;
$patch$;

-- ---------------------------------------------------------------------
-- CERTIFIED-CONTRACT PATCH 2/2 — cancel_building() refunds a demolition correctly.
-- Contract preserved: an upgrade still refunds calculate_building_cost(target_level) and
-- the returned row shape is untouched.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'cancel_building';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: cancel_building';
    end if;

    if position('is_downgrade' in v_src) > 0 then
        return; /* already patched */
    end if;

    v_old := '    select c.metal, c.crystal, c.deuterium
    into v_metal, v_crystal, v_deuterium
    from public.calculate_building_cost(v_queue.building_id, v_queue.target_level) c;';

    v_new := '    if coalesce(v_queue.is_downgrade, false) then
        /* DEMOLITION: refund exactly what was charged. target_level + 1 is the removed level. */
        select c.metal, c.crystal, c.deuterium
        into v_metal, v_crystal, v_deuterium
        from public.calculate_building_demolition_cost(
            v_queue.building_id,
            v_queue.target_level + 1,
            coalesce(public.get_player_research_level(v_owner, ''ion_technology''), 0)
        ) c;
    else
        select c.metal, c.crystal, c.deuterium
        into v_metal, v_crystal, v_deuterium
        from public.calculate_building_cost(v_queue.building_id, v_queue.target_level) c;
    end if;';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: cancel_building refund';
    end if;
    v_src := replace(v_src, v_old, v_new);

    execute v_src;
end;
$patch$;

-- ---------------------------------------------------------------------
-- ACL: least privilege. No anon bypass; the AI service actor uses service_role together
-- with lgi.ai_worker / lgi.ai_player (certified AI contract).
-- ---------------------------------------------------------------------
revoke all on function public.inspect_demolition(uuid, uuid, text) from public;
revoke all on function public.can_start_demolition(uuid, uuid, text) from public;
revoke all on function public.start_demolition(uuid, uuid, text) from public;
revoke all on function public.calculate_building_demolition_cost(text, integer, integer) from public;

grant execute on function public.inspect_demolition(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.can_start_demolition(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.start_demolition(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.calculate_building_demolition_cost(text, integer, integer) to anon, authenticated, service_role;
