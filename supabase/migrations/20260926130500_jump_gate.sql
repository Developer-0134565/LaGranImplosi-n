-- JUMP GATE (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- OGameX `JumpGateService` (@ 7c420bad): `BASE_COOLDOWN_MINUTES = 60` at fleet speed 1,
-- `COOLDOWN_REDUCTION_PER_LEVEL = 0.10`, `NON_TRANSFERABLE_SHIPS = { solar_satellite, crawler }`, the destination
-- moon must own a jump gate too, and NO deuterium is charged.
--
-- Owner-gated like every engine RPC (auth.uid() → players.user_id, or a service-role call that states the owner and
-- is still cross-checked), atomic (FOR UPDATE on the ships and the moons) and replay-safe: the source moon's cooldown
-- starts in the same transaction, so a second identical jump is refused until it expires.
begin;

create or replace function public.calculate_jump_gate_cooldown_seconds(p_jump_gate_level integer, p_universe_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select greatest(0, floor(
        (60.0 / greatest(1, coalesce(
            (select nullif(u.war_fleet_speed, 0) from public.universes u where u.id = p_universe_id),
            (select nullif(u.fleet_speed, 0) from public.universes u where u.id = p_universe_id),
            1))) * 60
        * (1 - 0.10 * greatest(0, coalesce(p_jump_gate_level, 1) - 1))))::integer;
$function$;

comment on function public.calculate_jump_gate_cooldown_seconds(integer, uuid) is
$c$OGameX JumpGateService::calculateCooldown: base 60 minutes divided by the war fleet speed of the universe, reduced
by 10 % per jump gate level above 1.$c$;

create or replace function public.execute_jump_gate(
    p_player_id uuid,
    p_source_moon_id uuid,
    p_target_moon_id uuid,
    p_ships jsonb
)
returns table(
    out_source_moon_id uuid,
    out_target_moon_id uuid,
    out_ships jsonb,
    out_cooldown_until timestamp with time zone,
    out_cooldown_seconds integer
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid;
    v_source public.planets%rowtype;
    v_target public.planets%rowtype;
    v_source_level integer := 0;
    v_target_level integer := 0;
    v_available bigint;
    v_quantity bigint;
    v_ship_id text;
    v_cooldown integer;
    v_until timestamp with time zone;
    v_non_transferable constant text[] := array['solar_satellite', 'crawler'];
    v_moved jsonb := '{}'::jsonb;
begin
    if p_source_moon_id is null or p_target_moon_id is null then
        raise exception 'JUMP_GATE_MOONS_REQUIRED';
    end if;

    if p_ships is null or jsonb_typeof(p_ships) <> 'object' or p_ships = '{}'::jsonb then
        raise exception 'JUMP_GATE_SHIPS_REQUIRED';
    end if;

    v_auth_user := auth.uid();

    select m.* into v_source from public.planets m
     where m.id = p_source_moon_id and m.kind = 'MOON' and not m.is_destroyed
     for update;
    if not found then
        raise exception 'JUMP_GATE_SOURCE_MOON_NOT_FOUND: %', p_source_moon_id;
    end if;

    select m.* into v_target from public.planets m
     where m.id = p_target_moon_id and m.kind = 'MOON' and not m.is_destroyed
     for update;
    if not found then
        raise exception 'JUMP_GATE_TARGET_MOON_NOT_FOUND: %', p_target_moon_id;
    end if;

    if v_source.id = v_target.id then
        raise exception 'JUMP_GATE_SAME_MOON';
    end if;

    if v_auth_user is not null then
        if not exists (select 1 from public.players pl
                        where pl.id = v_source.player_id and pl.user_id = v_auth_user) then
            raise exception 'JUMP_GATE_MOON_NOT_OWNED: %', p_source_moon_id;
        end if;
        if p_player_id is not null and p_player_id <> v_source.player_id then
            raise exception 'JUMP_GATE_MOON_NOT_OWNED: %', p_source_moon_id;
        end if;
    else
        if p_player_id is null or p_player_id <> v_source.player_id then
            raise exception 'JUMP_GATE_MOON_NOT_OWNED: %', p_source_moon_id;
        end if;
    end if;

    if v_target.player_id is distinct from v_source.player_id then
        raise exception 'JUMP_GATE_TARGET_MOON_NOT_OWNED: %', p_target_moon_id;
    end if;

    select coalesce(pb.level, 0) into v_source_level
      from public.planet_buildings pb
     where pb.planet_id = v_source.id and pb.building_id = 'jump_gate';
    if coalesce(v_source_level, 0) < 1 then
        raise exception 'JUMP_GATE_NOT_BUILT: %', p_source_moon_id;
    end if;

    select coalesce(pb.level, 0) into v_target_level
      from public.planet_buildings pb
     where pb.planet_id = v_target.id and pb.building_id = 'jump_gate';
    if coalesce(v_target_level, 0) < 1 then
        raise exception 'JUMP_GATE_TARGET_NOT_BUILT: %', p_target_moon_id;
    end if;

    if v_source.jump_gate_cooldown_until is not null
       and v_source.jump_gate_cooldown_until > clock_timestamp() then
        raise exception 'JUMP_GATE_ON_COOLDOWN: until %', v_source.jump_gate_cooldown_until;
    end if;

    for v_ship_id, v_quantity in
        select key, value::bigint from jsonb_each_text(p_ships) order by key
    loop
        if v_quantity is null or v_quantity <= 0 then
            raise exception 'JUMP_GATE_INVALID_QUANTITY: % = %', v_ship_id, v_quantity;
        end if;

        if v_ship_id = any (v_non_transferable) then
            raise exception 'JUMP_GATE_SHIP_NOT_TRANSFERABLE: %', v_ship_id;
        end if;

        if not exists (select 1 from public.ship_definitions sd where sd.id = v_ship_id) then
            raise exception 'JUMP_GATE_UNKNOWN_SHIP: %', v_ship_id;
        end if;

        select ps.quantity into v_available
          from public.planet_ships ps
         where ps.planet_id = v_source.id and ps.ship_id = v_ship_id
         for update;

        if coalesce(v_available, 0) < v_quantity then
            raise exception 'JUMP_GATE_SHIPS_UNAVAILABLE: % required %, available %',
                v_ship_id, v_quantity, coalesce(v_available, 0);
        end if;
    end loop;

    v_cooldown := public.calculate_jump_gate_cooldown_seconds(v_source_level, v_source.universe_id);
    v_until := clock_timestamp() + v_cooldown * interval '1 second';

    for v_ship_id, v_quantity in
        select key, value::bigint from jsonb_each_text(p_ships) order by key
    loop
        update public.planet_ships ps
           set quantity = ps.quantity - v_quantity
         where ps.planet_id = v_source.id and ps.ship_id = v_ship_id;

        delete from public.planet_ships ps
         where ps.planet_id = v_source.id and ps.ship_id = v_ship_id and ps.quantity <= 0;

        insert into public.planet_ships(planet_id, ship_id, quantity)
        values (v_target.id, v_ship_id, v_quantity)
        on conflict (planet_id, ship_id) do update
            set quantity = public.planet_ships.quantity + excluded.quantity;

        v_moved := v_moved || jsonb_build_object(v_ship_id, v_quantity);
    end loop;

    update public.planets m
       set jump_gate_cooldown_until = v_until
     where m.id = v_source.id;

    return query select v_source.id, v_target.id, v_moved, v_until, v_cooldown;
end;
$function$;

comment on function public.execute_jump_gate(uuid, uuid, uuid, jsonb) is
$c$OGame jump gate: teleports ships between two moons owned by the same player. Validations: both moons exist and are
moons, both own a jump gate, the caller owns them, the source is off cooldown, every ship exists, has a positive
quantity and is transferable (solar satellites and crawlers are not, per OGameX), and the source owns the quantity. The
move and the cooldown start are atomic; no deuterium is charged (OGameX charges none). ACL: authenticated/service_role
only, never anon.$c$;

revoke all on function public.calculate_jump_gate_cooldown_seconds(integer, uuid) from public, anon, authenticated;
grant execute on function public.calculate_jump_gate_cooldown_seconds(integer, uuid) to service_role;
revoke all on function public.execute_jump_gate(uuid, uuid, uuid, jsonb) from public, anon;
grant execute on function public.execute_jump_gate(uuid, uuid, uuid, jsonb) to authenticated;
grant execute on function public.execute_jump_gate(uuid, uuid, uuid, jsonb) to service_role;

commit;

