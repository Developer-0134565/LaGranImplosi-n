-- LGI SWEEP III - #1 Wreck field + Space Dock (migration 20260926230000)
-- OGameX reference: WreckFieldService (loadOrCreateForCoordinates / canCreateWreckField /
--   calculateShipsForWreckField / extendWreckField / startRepairs / completeRepairs / burn) and its
--   CleanupWreckFields scheduled command. LGI decisions (documented in the migration header of the repo
--   copy and in docs/systems/README_FLEET_ENGINE.md):
--   * one wreck field per coordinate; a new battle EXTENDS it and refreshes the decay timer (72 h)
--   * Space Dock price curve is LGI-defined (400/200/100, factor 2, time factor 2, max 10, planets+moons)
--   * recoverable share = least(100, 20 + 8 * space_dock_level) % ; repair rate = 5 * level ships/hour
--   * repairs are free (time only) ; states ACTIVE / REPAIRING / BLOCKED (no Space Dock)
--   * only ship units enter the field: the join against ship_definitions excludes defences
--   * producer = additive AFTER UPDATE trigger on combat_battles (same pattern as the moon destruction
--     hook): no certified combat function is modified and the trigger never breaks a battle
create table if not exists public.planet_wreck_fields (
    id uuid primary key default gen_random_uuid(),
    planet_id uuid not null unique references public.planets(id) on delete cascade,
    owner_player_id uuid not null references public.players(id) on delete cascade,
    status text not null default 'ACTIVE' check (status in ('ACTIVE','REPAIRING','BLOCKED')),
    space_dock_level integer not null default 0 check (space_dock_level >= 0),
    blocked_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    expires_at timestamptz not null default now() + interval '72 hours',
    repair_started_at timestamptz,
    repair_finishes_at timestamptz
);
create table if not exists public.planet_wreck_field_ships (
    wreck_field_id uuid not null references public.planet_wreck_fields(id) on delete cascade,
    ship_id text not null references public.ship_definitions(id) on delete cascade,
    quantity bigint not null check (quantity > 0),
    repaired_quantity bigint not null default 0 check (repaired_quantity >= 0),
    primary key (wreck_field_id, ship_id)
);
create index if not exists planet_wreck_fields_status_expires_idx on public.planet_wreck_fields (status, expires_at);
insert into public.building_definitions (id, name, description, base_metal, base_crystal, base_deuterium, cost_factor, base_build_time_seconds, time_factor, max_level, valid_kinds)
select 'space_dock', 'Dique Espacial', 'Repara las naves destruidas en el campo de restos de este planeta o luna. Cada nivel recupera un 8 % mas de las naves y acelera la reparacion.', 400, 200, 100, 2, 3600, 2, 10, array['PLANET','MOON']::text[]
where not exists (select 1 from public.building_definitions where id = 'space_dock');
create or replace function public.wreck_field_space_dock_level(p_planet_id uuid)
returns integer language sql stable security definer set search_path to 'public','pg_temp' as $f$
    select coalesce((select pb.level from public.planet_buildings pb where pb.planet_id = p_planet_id and pb.building_id = 'space_dock'), 0);
$f$;
create or replace function public.wreck_field_recover_percent(p_space_dock_level integer)
returns numeric language sql immutable as $f$
    select least(100, 20 + 8 * greatest(coalesce(p_space_dock_level, 0), 0))::numeric;
$f$;
create or replace function public.create_or_extend_wreck_field(p_planet_id uuid, p_ships jsonb, p_space_dock_level integer default null)
returns uuid language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare
    v_owner uuid; v_level integer; v_percent numeric; v_field_id uuid; v_ship_id text;
    v_destroyed bigint; v_recoverable bigint; v_added integer := 0;
begin
    if p_ships is null or jsonb_typeof(p_ships) <> 'object' then return null; end if;
    select p.player_id into v_owner from public.planets p where p.id = p_planet_id and p.is_destroyed = false;
    if v_owner is null then return null; end if;
    v_level := coalesce(p_space_dock_level, public.wreck_field_space_dock_level(p_planet_id));
    v_percent := public.wreck_field_recover_percent(v_level);
    select wf.id into v_field_id from public.planet_wreck_fields wf where wf.planet_id = p_planet_id;
    if v_field_id is null then
        insert into public.planet_wreck_fields (planet_id, owner_player_id, status, space_dock_level)
        values (p_planet_id, v_owner, 'ACTIVE', v_level) returning id into v_field_id;
    else
        update public.planet_wreck_fields set space_dock_level = v_level, updated_at = now(),
               expires_at = greatest(expires_at, now() + interval '72 hours') where id = v_field_id;
    end if;
    for v_ship_id, v_destroyed in select key, (value)::bigint from jsonb_each_text(p_ships) loop
        if v_destroyed is null or v_destroyed <= 0 then continue; end if;
        if not exists (select 1 from public.ship_definitions sd where sd.id = v_ship_id) then continue; end if;
        v_recoverable := floor(v_destroyed * v_percent / 100.0)::bigint;
        if v_recoverable <= 0 then continue; end if;
        insert into public.planet_wreck_field_ships (wreck_field_id, ship_id, quantity)
        values (v_field_id, v_ship_id, v_recoverable)
        on conflict (wreck_field_id, ship_id) do update set quantity = public.planet_wreck_field_ships.quantity + excluded.quantity;
        v_added := v_added + 1;
    end loop;
    if v_added = 0 and not exists (select 1 from public.planet_wreck_field_ships s where s.wreck_field_id = v_field_id) then
        delete from public.planet_wreck_fields where id = v_field_id;
        return null;
    end if;
    update public.planet_wreck_fields set updated_at = now() where id = v_field_id;
    return v_field_id;
end;
$f$;
create or replace function public.settle_wreck_field_for_battle(p_battle_id uuid)
returns uuid language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_planet_id uuid; v_ships jsonb;
begin
    select cb.defender_planet_id into v_planet_id from public.combat_battles cb
     where cb.id = p_battle_id and cb.defender_planet_id is not null;
    if v_planet_id is null then return null; end if;
    select coalesce(jsonb_object_agg(x.ship_id, x.destroyed), '{}'::jsonb) into v_ships
      from (select u.unit_id as ship_id, sum(greatest(u.quantity - u.quantity_alive, 0)) as destroyed
              from (select distinct on (cus.unit_id) cus.unit_id, cus.quantity, cus.quantity_alive
                      from public.combat_unit_state cus where cus.battle_id = p_battle_id
                     order by cus.unit_id, cus.round_number desc) u
              join public.ship_definitions sd on sd.id = u.unit_id
             group by u.unit_id
            having sum(greatest(u.quantity - u.quantity_alive, 0)) > 0) x;
    if v_ships is null or v_ships = '{}'::jsonb then return null; end if;
    return public.create_or_extend_wreck_field(v_planet_id, v_ships);
end;
$f$;
create or replace function public.on_combat_battle_finished_wreck_field()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
    begin
        perform public.settle_wreck_field_for_battle(new.id);
    exception when others then
        raise warning 'wreck field settlement failed for battle %: %', new.id, sqlerrm;
    end;
    return new;
end;
$f$;
drop trigger if exists trg_on_combat_battle_finished_wreck_field on public.combat_battles;
create trigger trg_on_combat_battle_finished_wreck_field after update on public.combat_battles
    for each row when (old.finished_at is null and new.finished_at is not null)
    execute function public.on_combat_battle_finished_wreck_field();
create or replace function public.start_wreck_field_repairs(p_wreck_field_id uuid)
returns table (out_field_id uuid, out_status text, out_result text, out_ships_total bigint, out_finishes_at timestamptz)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_field public.planet_wreck_fields%rowtype; v_total bigint; v_rate numeric; v_hours numeric; v_level integer;
begin
    select * into v_field from public.planet_wreck_fields wf where wf.id = p_wreck_field_id for update;
    if not found then return query select p_wreck_field_id, null::text, 'NOT_FOUND', 0::bigint, null::timestamptz; return; end if;
    if v_field.status = 'REPAIRING' then
        return query select v_field.id, v_field.status, 'ALREADY_REPAIRING', 0::bigint, v_field.repair_finishes_at; return;
    end if;
    select coalesce(sum(s.quantity - s.repaired_quantity), 0) into v_total from public.planet_wreck_field_ships s where s.wreck_field_id = v_field.id;
    v_level := greatest(v_field.space_dock_level, public.wreck_field_space_dock_level(v_field.planet_id));
    if v_level <= 0 then
        update public.planet_wreck_fields set status = 'BLOCKED', blocked_reason = 'NO_SPACE_DOCK', updated_at = now() where id = v_field.id;
        return query select v_field.id, 'BLOCKED'::text, 'NO_SPACE_DOCK', v_total, null::timestamptz; return;
    end if;
    if v_total <= 0 then
        delete from public.planet_wreck_fields where id = v_field.id;
        return query select v_field.id, 'BURNED'::text, 'NOTHING_TO_REPAIR', 0::bigint, null::timestamptz; return;
    end if;
    v_rate := 5 * v_level;
    v_hours := ceil(v_total / v_rate);
    update public.planet_wreck_fields set status = 'REPAIRING', blocked_reason = null, space_dock_level = v_level,
           repair_started_at = now(), repair_finishes_at = now() + (v_hours || ' hours')::interval, updated_at = now()
     where id = v_field.id;
    return query select v_field.id, 'REPAIRING'::text, 'STARTED', v_total, now() + (v_hours || ' hours')::interval;
end;
$f$;
create or replace function public.complete_wreck_field_repairs(p_wreck_field_id uuid)
returns table (out_field_id uuid, out_result text, out_ships_repaired bigint)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_field public.planet_wreck_fields%rowtype; v_row record; v_repaired bigint := 0;
begin
    select * into v_field from public.planet_wreck_fields wf where wf.id = p_wreck_field_id for update;
    if not found or v_field.status <> 'REPAIRING' or v_field.repair_finishes_at is null or v_field.repair_finishes_at > now() then
        return query select p_wreck_field_id, 'NOT_DUE'::text, 0::bigint; return;
    end if;
    for v_row in select s.ship_id, s.quantity - s.repaired_quantity as pending from public.planet_wreck_field_ships s
                  where s.wreck_field_id = v_field.id and s.quantity > s.repaired_quantity order by s.ship_id loop
        if v_row.pending <= 0 then continue; end if;
        insert into public.planet_ships (planet_id, ship_id, quantity) values (v_field.planet_id, v_row.ship_id, v_row.pending)
        on conflict (planet_id, ship_id) do update set quantity = public.planet_ships.quantity + excluded.quantity;
        update public.planet_wreck_field_ships set repaired_quantity = quantity where wreck_field_id = v_field.id and ship_id = v_row.ship_id;
        v_repaired := v_repaired + v_row.pending;
    end loop;
    delete from public.planet_wreck_fields where id = v_field.id;
    return query select v_field.id, 'COMPLETED'::text, v_repaired;
end;
$f$;
create or replace function public.run_wreck_field_worker(p_limit integer default 100)
returns table (wreck_field_id uuid, planet_id uuid, outcome text, ships_moved bigint)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_row record; v_res record;
begin
    for v_row in select wf.id from public.planet_wreck_fields wf
                  where wf.status = 'REPAIRING' and wf.repair_finishes_at <= now()
                  order by wf.repair_finishes_at limit greatest(coalesce(p_limit, 100), 1) loop
        select * into v_res from public.complete_wreck_field_repairs(v_row.id);
        return query select v_res.out_field_id, null::uuid, v_res.out_result, coalesce(v_res.out_ships_repaired, 0);
    end loop;
    for v_row in select wf.id, wf.planet_id from public.planet_wreck_fields wf
                  where wf.status in ('ACTIVE','BLOCKED') and wf.expires_at <= now()
                  order by wf.expires_at limit greatest(coalesce(p_limit, 100), 1) loop
        delete from public.planet_wreck_fields where id = v_row.id;
        return query select v_row.id, v_row.planet_id, 'DECAYED'::text, 0::bigint;
    end loop;
end;
$f$;
revoke all on function public.create_or_extend_wreck_field(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function public.start_wreck_field_repairs(uuid) from public, anon, authenticated;
revoke all on function public.complete_wreck_field_repairs(uuid) from public, anon, authenticated;
revoke all on function public.run_wreck_field_worker(integer) from public, anon, authenticated;
revoke all on function public.settle_wreck_field_for_battle(uuid) from public, anon, authenticated;
grant execute on function public.create_or_extend_wreck_field(uuid, jsonb, integer) to service_role;
grant execute on function public.start_wreck_field_repairs(uuid) to service_role;
grant execute on function public.complete_wreck_field_repairs(uuid) to service_role;
grant execute on function public.run_wreck_field_worker(integer) to service_role;
grant execute on function public.settle_wreck_field_for_battle(uuid) to service_role;
do $sched$
begin
    if exists (select 1 from pg_extension where extname = 'pg_cron') then
        if exists (select 1 from cron.job where jobname = 'lagranimplosion-wreck-field-worker') then
            perform cron.unschedule('lagranimplosion-wreck-field-worker');
        end if;
        perform cron.schedule('lagranimplosion-wreck-field-worker', '*/10 * * * *', 'select public.run_wreck_field_worker(200)');
    end if;
end;
$sched$;