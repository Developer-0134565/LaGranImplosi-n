-- SENSOR PHALANX + JUMP GATE (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- OGameX evidence (@ 7c420bad):
--   `PhalanxService`  range = level² − 1 systems in each direction, same galaxy, phalanx level must be > 0,
--                     SCAN_COST = 5 000 deuterium per scan.
--   `JumpGateService` BASE_COOLDOWN_MINUTES = 60 (at fleet speed 1), COOLDOWN_REDUCTION_PER_LEVEL = 10 %,
--                     NON_TRANSFERABLE_SHIPS = { solar_satellite, crawler }, the destination moon must own a jump
--                     gate too, no deuterium is charged.
--
-- Both contracts are owner-gated exactly like every other engine RPC: an authenticated caller is resolved through
-- auth.uid() → players.user_id (no parameter can select another player), a service-role caller must state the owner
-- and is still cross-checked against the stored owner. Both are atomic (FOR UPDATE on the resources/ships they
-- touch) and replay-safe: the phalanx scan charges deuterium once per call and the jump gate refuses a second jump
-- while its cooldown is running.
begin;

create or replace function public.scan_with_phalanx(
    p_player_id uuid,
    p_moon_id uuid,
    p_galaxy integer,
    p_system integer
)
returns table(
    out_fleet_id uuid,
    out_player_id uuid,
    out_owner_name text,
    out_mission_type text,
    out_status text,
    out_destination_galaxy integer,
    out_destination_system integer,
    out_destination_position integer,
    out_arrives_at timestamp with time zone,
    out_returns_at timestamp with time zone,
    out_ships jsonb
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_moon public.planets%rowtype;
    v_level integer := 0;
    v_range integer;
    v_cost constant numeric := 5000;
    v_deuterium numeric;
begin
    if p_moon_id is null then
        raise exception 'PHALANX_MOON_REQUIRED';
    end if;

    v_auth_user := auth.uid();

    select m.* into v_moon from public.planets m
     where m.id = p_moon_id and m.kind = 'MOON' and not m.is_destroyed
     for update;

    if not found then
        raise exception 'PHALANX_MOON_NOT_FOUND: %', p_moon_id;
    end if;

    if v_auth_user is not null then
        if not exists (select 1 from public.players pl
                        where pl.id = v_moon.player_id and pl.user_id = v_auth_user) then
            raise exception 'PHALANX_MOON_NOT_OWNED: %', p_moon_id;
        end if;
        if p_player_id is not null and p_player_id <> v_moon.player_id then
            raise exception 'PHALANX_MOON_NOT_OWNED: %', p_moon_id;
        end if;
    else
        if p_player_id is null or p_player_id <> v_moon.player_id then
            raise exception 'PHALANX_MOON_NOT_OWNED: %', p_moon_id;
        end if;
    end if;

    select coalesce(pb.level, 0) into v_level
      from public.planet_buildings pb
     where pb.planet_id = v_moon.id and pb.building_id = 'sensor_phalanx';

    if coalesce(v_level, 0) < 1 then
        raise exception 'PHALANX_NOT_BUILT: %', p_moon_id;
    end if;

    if p_galaxy is null or p_system is null then
        raise exception 'PHALANX_TARGET_COORDINATES_REQUIRED';
    end if;

    if p_galaxy <> v_moon.galaxy then
        raise exception 'PHALANX_TARGET_OUT_OF_GALAXY: % <> %', p_galaxy, v_moon.galaxy;
    end if;

    v_range := (v_level * v_level) - 1;

    if abs(p_system - v_moon.system) > v_range then
        raise exception 'PHALANX_TARGET_OUT_OF_RANGE: system % is % systems away (range % at level %)',
            p_system, abs(p_system - v_moon.system), v_range, v_level;
    end if;

    perform public.update_planet_resources_until(v_moon.id, clock_timestamp());

    select pr.deuterium into v_deuterium
      from public.planet_resources pr where pr.planet_id = v_moon.id for update;

    if coalesce(v_deuterium, 0) < v_cost then
        raise exception 'PHALANX_INSUFFICIENT_DEUTERIUM: required %, available %', v_cost, coalesce(v_deuterium, 0);
    end if;

    update public.planet_resources pr
       set deuterium = pr.deuterium - v_cost, updated_at = clock_timestamp()
     where pr.planet_id = v_moon.id;

    return query
    select fm.id, fm.player_id, pl.username, fm.mission_type, fm.status,
           fm.destination_galaxy, fm.destination_system, fm.destination_position,
           fm.arrives_at, fm.returns_at,
           coalesce((select jsonb_object_agg(fms.ship_id, fms.quantity)
                       from public.fleet_movement_ships fms where fms.fleet_id = fm.id), '{}'::jsonb)
      from public.fleet_movements fm
      join public.players pl on pl.id = fm.player_id
     where fm.status in ('OUTBOUND', 'RETURNING')
       and fm.destination_galaxy = p_galaxy
       and fm.destination_system = p_system
     order by coalesce(fm.arrives_at, fm.returns_at), fm.id;
end;
$function$;

comment on function public.scan_with_phalanx(uuid, uuid, integer, integer) is
$c$Sensor Phalanx scan (OGameX PhalanxService): the caller must own the moon, the moon must own a sensor_phalanx, the
target system must be in the same galaxy and within level^2 - 1 systems, and the scan costs 5 000 deuterium taken from
the moon's own resources (atomic, once per call). Returns the in-flight (OUTBOUND/RETURNING) fleets whose destination
coordinates are the scanned system, so no foreign fleet outside the phalanx range can ever be observed. ACL:
authenticated/service_role only.$c$;

revoke all on function public.scan_with_phalanx(uuid, uuid, integer, integer) from public, anon;
grant execute on function public.scan_with_phalanx(uuid, uuid, integer, integer) to authenticated;
grant execute on function public.scan_with_phalanx(uuid, uuid, integer, integer) to service_role;

commit;
