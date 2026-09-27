-- FLEET RECALL — server-side, owner-gated, atomic (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Product decision of the GAMEPLAY COMPLETION SWEEP: recall is implemented for every mission that can be
-- recalled, server-side and owner-gated.
--
-- OGame rule kept exactly (OGameX `FleetMissionService::cancelMission()` + per-mission `cancel()` @ 7c420bad):
--   * a mission can only be recalled while it has NOT arrived (`time_arrival < now` → refused) or while an
--     ACS-HOLD fleet is inside its hold window;
--   * the recall turns the fleet around at the position it has REACHED, so the return leg lasts exactly as long
--     as the outbound leg already flown — nothing is teleported and no speed is recalculated;
--   * a fleet recalled from its hold returns with the complete outbound duration (it is at the destination);
--   * the cargo the fleet carries at the instant of the recall is preserved byte-for-byte: the recall writes
--     only `status` and `returns_at`, never `metal`/`crystal`/`deuterium` nor `fleet_movement_ships`;
--   * the canonical lifecycle is reused (status = RETURNING + the worker's existing RETURNING branch), so no new
--     state and no CANCELLED row is invented and the queue-cancellation contract is untouched.
--
-- Replay safety: the transition is guarded by `where id = ... and status = <old status>`; a second identical
-- call finds a RETURNING fleet and is refused with FLEET_NOT_RECALLABLE, so a fleet can never be returned twice.
-- Concurrency: the row is locked with FOR UPDATE and the guarded UPDATE is the only writer, so exactly one
-- caller wins; the loser gets FLEET_RECALL_RACE_LOST.
--
-- Certified by `supabase/tests/fleet_recall.sql`.
begin;

create or replace function public.recall_fleet(p_player_id uuid, p_fleet_id uuid)
returns table(
    out_fleet_id uuid,
    out_status text,
    out_mission_type text,
    out_origin_planet_id uuid,
    out_returns_at timestamp with time zone,
    out_seconds_remaining integer,
    out_cargo_metal numeric,
    out_cargo_crystal numeric,
    out_cargo_deuterium numeric,
    out_ships jsonb
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_fleet public.fleet_movements%rowtype;
    v_now timestamp with time zone;
    v_flown interval;
    v_returns_at timestamp with time zone;
begin
    if p_fleet_id is null then
        raise exception 'FLEET_ID_REQUIRED';
    end if;

    v_auth_user := auth.uid();

    select fm.* into v_fleet
    from public.fleet_movements fm
    where fm.id = p_fleet_id
    for update;

    if not found then
        raise exception 'FLEET_NOT_FOUND: %', p_fleet_id;
    end if;

    /*
      Ownership. An authenticated caller must own the fleet (auth.uid() -> players.user_id); a service-role
      caller has no session and must state the owning player explicitly. A client-supplied p_player_id is never
      trusted on its own: it is only ever compared against the fleet's stored owner.
    */
    if v_auth_user is not null then
        if not exists (select 1
                         from public.players pl
                        where pl.id = v_fleet.player_id
                          and pl.user_id = v_auth_user) then
            raise exception 'FLEET_NOT_OWNED: %', p_fleet_id;
        end if;

        if p_player_id is not null and p_player_id <> v_fleet.player_id then
            raise exception 'FLEET_NOT_OWNED: %', p_fleet_id;
        end if;
    else
        if p_player_id is null or p_player_id <> v_fleet.player_id then
            raise exception 'FLEET_NOT_OWNED: %', p_fleet_id;
        end if;
    end if;

    v_now := clock_timestamp();

    if v_fleet.status = 'OUTBOUND' then
        if v_fleet.arrives_at <= v_now then
            raise exception 'FLEET_RECALL_TOO_LATE: %', p_fleet_id;
        end if;

        /* Mirror rule: the return leg lasts as long as the time already flown. */
        v_flown := v_now - v_fleet.started_at;
        v_returns_at := v_now + v_flown;

        update public.fleet_movements
        set status = 'RETURNING',
            returns_at = v_returns_at
        where id = p_fleet_id
          and status = 'OUTBOUND';

        if not found then
            raise exception 'FLEET_RECALL_RACE_LOST: %', p_fleet_id;
        end if;

    elsif v_fleet.status = 'HOLDING' then
        /* A holding fleet sits at the destination: the recall repeats the outbound duration. */
        v_flown := v_fleet.arrives_at - v_fleet.started_at;
        v_returns_at := v_now + v_flown;

        update public.fleet_movements
        set status = 'RETURNING',
            returns_at = v_returns_at
        where id = p_fleet_id
          and status = 'HOLDING';

        if not found then
            raise exception 'FLEET_RECALL_RACE_LOST: %', p_fleet_id;
        end if;

    else
        raise exception 'FLEET_NOT_RECALLABLE: % (status %)', p_fleet_id, v_fleet.status;
    end if;

    return query
    select fm.id,
           fm.status,
           fm.mission_type,
           fm.origin_planet_id,
           fm.returns_at,
           greatest(0, floor(extract(epoch from (fm.returns_at - v_now))))::integer,
           fm.metal,
           fm.crystal,
           fm.deuterium,
           coalesce((select jsonb_object_agg(fms.ship_id, fms.quantity)
                       from public.fleet_movement_ships fms
                      where fms.fleet_id = fm.id), '{}'::jsonb)
    from public.fleet_movements fm
    where fm.id = p_fleet_id;
end;
$function$;

comment on function public.recall_fleet(uuid, uuid) is
$c$Recalls one of the caller's own fleets. Owner-gated (auth.uid() -> players.user_id; a service-role call must state
the owning player and is still cross-checked against the stored owner), atomic (FOR UPDATE + guarded UPDATE) and
replay-safe (a second call is refused). OUTBOUND fleets return with a return leg equal to the time already flown;
HOLDING fleets return with the full outbound duration. The cargo and the surviving composition are preserved
exactly, the status transition is the canonical RETURNING one, and the fleet owner is notified by the messaging
engine. Clients: EXECUTE for authenticated/service_role, never anon.$c$;

revoke all on function public.recall_fleet(uuid, uuid) from public, anon;
grant execute on function public.recall_fleet(uuid, uuid) to authenticated;
grant execute on function public.recall_fleet(uuid, uuid) to service_role;

commit;
