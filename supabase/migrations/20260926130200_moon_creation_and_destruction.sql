-- MOON CREATION (combat) + MOON DESTRUCTION (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- CREATION — OGameX `BattleEngine::calculateMoonChance` / `rollMoonCreation` +
-- `PlanetServiceFactory::setupMoonProperties` (@ 7c420bad):
--     chance% = floor(debris_total / 100 000), clamped to the universe maximum (LGI has no setting column, so the
--               classic OGame maximum of 20 % is applied and documented as a constant, not invented per-run);
--     roll    = 1..100 <= chance;
--     diameter = floor(sqrt(x + 3 × debris / 100 000) × 1000), x ∈ [10,20], capped at 8 944 km;
--     fields  = 1 (+3 per lunar base level, see the field-capacity trigger);
--     temp    = average of the parent planet's temperatures (max), min = max − 40.
--   The hook is an AFTER INSERT trigger on `combat_debris_generations`: that table already records exactly one row
--   per battle that produced debris (`create_combat_debris` is idempotent by battle_id), so the roll happens once and
--   only for battles whose debris can actually form a moon. The certified combat path is NOT modified.
--   The roll is deterministic (`fleet_event_random` on the attacking fleet), i.e. replay-safe by construction.
--
-- DESTRUCTION — OGameX `MoonDestructionMission` (verified verbatim):
--     only against a foreign moon, requires ≥ 1 Deathstar in the attacking fleet;
--     success%    = clamp(0, 100, (100 − sqrt(diameter)) × sqrt(deathstars));
--     RIP loss%   = clamp(0, 100, sqrt(diameter) / 2)   (applied only when the moon survives).
--   The battle itself is resolved by the certified engine (the attack on the moon is a normal ATTACK); this trigger
--   only applies the moon-specific outcome when the battle FINISHES, keyed by `combat_battles.finished_at`
--   (null → not null happens once) and logged in `moon_destruction_attempts` (unique per battle) for provenance and
--   idempotency.
--   A destroyed moon keeps its row (`is_destroyed = true`, relations intact) and loses its ships (→ debris at the
--   same coordinates), buildings and defences; its resources are zeroed.
begin;

create table if not exists public.moon_creation_rolls (
    battle_id uuid primary key references public.combat_battles(id) on delete cascade,
    planet_id uuid not null references public.planets(id) on delete cascade,
    debris_total numeric not null,
    moon_chance integer not null,
    roll integer not null,
    x_factor integer,
    diameter_km integer,
    moon_id uuid references public.planets(id) on delete set null,
    created_at timestamp with time zone not null default now()
);

comment on table public.moon_creation_rolls is
$c$One row per battle whose debris was evaluated for moon creation: the debris total, the OGameX chance, the
deterministic roll and the resulting diameter/moon (null when the roll failed). Replay-safe provenance.$c$;

create table if not exists public.moon_destruction_attempts (
    battle_id uuid primary key references public.combat_battles(id) on delete cascade,
    moon_id uuid not null references public.planets(id) on delete cascade,
    moon_diameter_km integer not null,
    deathstars bigint not null,
    success_chance integer not null,
    roll integer not null,
    destroyed boolean not null,
    deathstars_lost bigint not null default 0,
    created_at timestamp with time zone not null default now()
);

comment on table public.moon_destruction_attempts is
$c$One row per finished battle that carried at least one Deathstar against a moon: the OGameX success chance, the
deterministic roll, the outcome and the Deathstars lost on failure. Unique per battle → replay-safe.$c$;

create or replace function public.calculate_moon_creation_chance(p_debris_total numeric)
returns integer
language sql
immutable
as $function$
    select greatest(0, least(20, floor(coalesce(p_debris_total, 0) / 100000)))::integer;
$function$;

comment on function public.calculate_moon_creation_chance(numeric) is
$c$OGameX BattleEngine::calculateMoonChance: floor(debris / 100 000) clamped to the universe maximum. LGI has no
`maximumMoonChance` setting, so the classic OGame maximum of 20 % is applied as a documented constant.$c$;

create or replace function public.settle_moon_creation_for_battle(p_battle_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_battle record;
    v_planet public.planets%rowtype;
    v_debris numeric := 0;
    v_chance integer := 0;
    v_roll integer;
    v_x integer;
    v_diameter integer;
    v_avg_temp integer;
    v_moon_id uuid;
begin
    select cb.id, cb.fleet_id, cb.defender_planet_id into v_battle
      from public.combat_battles cb where cb.id = p_battle_id;
    if v_battle.defender_planet_id is null then
        return null;
    end if;

    select p.* into v_planet from public.planets p where p.id = v_battle.defender_planet_id for update;
    if not found or v_planet.kind <> 'PLANET' or v_planet.is_destroyed then
        return null;
    end if;

    /* a planet that already has a moon cannot receive a second one */
    if exists (select 1 from public.planets m where m.parent_planet_id = v_planet.id and not m.is_destroyed) then
        return null;
    end if;

    select coalesce(d.debris_metal, 0) + coalesce(d.debris_crystal, 0) into v_debris
      from public.calculate_combat_total_debris(p_battle_id) d;

    v_chance := public.calculate_moon_creation_chance(v_debris);

    v_roll := floor(public.fleet_event_random(v_battle.fleet_id, 'moon_creation') * 100) + 1;

    insert into public.moon_creation_rolls(battle_id, planet_id, debris_total, moon_chance, roll)
    values (p_battle_id, v_planet.id, v_debris, v_chance, v_roll)
    on conflict (battle_id) do nothing;

    if v_chance <= 0 or v_roll > v_chance then
        return null;
    end if;

    v_x := 10 + floor(public.fleet_event_random(v_battle.fleet_id, 'moon_x_factor') * 11);
    v_diameter := least(8944, floor(sqrt(v_x + (3 * v_debris / 100000)) * 1000));
    v_avg_temp := floor((coalesce(v_planet.temperature_min, 0) + coalesce(v_planet.temperature_max, 0)) / 2.0);

    insert into public.planets(universe_id, player_id, name, galaxy, system, position,
        temperature_min, temperature_max, fields_total, fields_used, is_homeworld, is_destroyed,
        kind, parent_planet_id, moon_diameter_km)
    values (v_planet.universe_id, v_planet.player_id, 'Moon', v_planet.galaxy, v_planet.system, v_planet.position,
        v_avg_temp - 40, v_avg_temp, 1, 0, false, false,
        'MOON', v_planet.id, v_diameter)
    returning id into v_moon_id;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_moon_id, 0, 0, 0, 0, clock_timestamp())
    on conflict (planet_id) do nothing;

    update public.moon_creation_rolls
       set x_factor = v_x, diameter_km = v_diameter, moon_id = v_moon_id
     where battle_id = p_battle_id;

    perform public.create_player_message(
        v_planet.player_id, null, 'Moon formed',
        format('The debris of the battle at %s collapsed into a moon of %s km.',
               public.format_coordinates(v_planet.galaxy, v_planet.system, v_planet.position), v_diameter),
        'moon_created:' || v_moon_id::text);

    return v_moon_id;
exception when others then
    raise warning 'MOON_CREATION_FAILED battle=% error=%', p_battle_id, sqlerrm;
    return null;
end;
$function$;

comment on function public.settle_moon_creation_for_battle(uuid) is
$c$Evaluates moon creation for a battle that produced debris (OGameX chance/diameter formulas, deterministic roll) and
creates the moon with its own resources when the roll succeeds. Called by the AFTER INSERT trigger on
combat_debris_generations, so it runs exactly once per battle and never blocks the combat path (failures only raise a
WARNING).$c$;

create or replace function public.settle_moon_destruction_for_battle(p_battle_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_battle record;
    v_moon public.planets%rowtype;
    v_deathstars bigint := 0;
    v_success_chance integer;
    v_loss_chance integer;
    v_roll integer;
    v_destroyed boolean := false;
    v_lost bigint := 0;
    v_debris_metal numeric := 0;
    v_debris_crystal numeric := 0;
    v_debris_pct numeric := 0;
    n integer;
begin
    select cb.id, cb.fleet_id, cb.defender_planet_id into v_battle
      from public.combat_battles cb where cb.id = p_battle_id;
    if v_battle.defender_planet_id is null then
        return null;
    end if;

    if exists (select 1 from public.moon_destruction_attempts a where a.battle_id = p_battle_id) then
        return null;
    end if;

    select m.* into v_moon from public.planets m
     where m.id = v_battle.defender_planet_id and m.kind = 'MOON' and not m.is_destroyed
     for update;
    if not found then
        return null;
    end if;

    select coalesce(sum(fms.quantity), 0) into v_deathstars
      from public.fleet_movement_ships fms
     where fms.fleet_id = v_battle.fleet_id and fms.ship_id = 'deathstar';
    if v_deathstars <= 0 then
        return null;
    end if;

    v_success_chance := least(100, greatest(0,
        floor((100 - sqrt(v_moon.moon_diameter_km)) * sqrt(v_deathstars))))::integer;
    v_roll := floor(public.fleet_event_random(v_battle.fleet_id, 'moon_destruction') * 100) + 1;
    v_destroyed := v_roll <= v_success_chance;

    if v_destroyed then
        select coalesce(u.fleet_debris_percentage, 0) into v_debris_pct
          from public.universes u where u.id = v_moon.universe_id;

        select coalesce(sum(ps.quantity * sd.base_metal), 0), coalesce(sum(ps.quantity * sd.base_crystal), 0)
          into v_debris_metal, v_debris_crystal
          from public.planet_ships ps
          join public.ship_definitions sd on sd.id = ps.ship_id
         where ps.planet_id = v_moon.id;

        v_debris_metal := floor(v_debris_metal * coalesce(v_debris_pct, 0) / 100.0);
        v_debris_crystal := floor(v_debris_crystal * coalesce(v_debris_pct, 0) / 100.0);

        if v_debris_metal > 0 or v_debris_crystal > 0 then
            perform public.add_debris_field(v_moon.universe_id, v_moon.galaxy, v_moon.system, v_moon.position,
                                            v_debris_metal, v_debris_crystal);
        end if;

        delete from public.planet_ships ps where ps.planet_id = v_moon.id;
        delete from public.planet_buildings pb where pb.planet_id = v_moon.id;
        delete from public.planet_defenses pd where pd.planet_id = v_moon.id;

        update public.planet_resources pr
           set metal = 0, crystal = 0, deuterium = 0, energy = 0, updated_at = clock_timestamp()
         where pr.planet_id = v_moon.id;

        update public.planets m
           set is_destroyed = true, fields_used = 0, fields_total = 0
         where m.id = v_moon.id;
    else
        v_loss_chance := least(100, greatest(0, floor(sqrt(v_moon.moon_diameter_km) / 2)))::integer;

        for n in 1..v_deathstars loop
            if floor(public.fleet_event_random(v_battle.fleet_id, 'moon_destruction_rip', n) * 100) + 1
               <= v_loss_chance then
                v_lost := v_lost + 1;
            end if;
        end loop;

        if v_lost > 0 then
            update public.fleet_movement_ships fms
               set quantity = fms.quantity - v_lost
             where fms.fleet_id = v_battle.fleet_id and fms.ship_id = 'deathstar';

            delete from public.fleet_movement_ships fms
             where fms.fleet_id = v_battle.fleet_id and fms.ship_id = 'deathstar' and fms.quantity <= 0;
        end if;
    end if;

    insert into public.moon_destruction_attempts(battle_id, moon_id, moon_diameter_km, deathstars,
        success_chance, roll, destroyed, deathstars_lost)
    values (p_battle_id, v_moon.id, v_moon.moon_diameter_km, v_deathstars,
        v_success_chance, v_roll, v_destroyed, v_lost)
    on conflict (battle_id) do nothing;

    if v_moon.player_id is not null then
        begin
            perform public.create_player_message(
                v_moon.player_id, null,
                case when v_destroyed then 'Moon destroyed' else 'Moon survived' end,
                format('The moon at %s with diameter %s km %s (destruction chance %s%%, roll %s).',
                       public.format_coordinates(v_moon.galaxy, v_moon.system, v_moon.position),
                       v_moon.moon_diameter_km,
                       case when v_destroyed then 'was destroyed' else 'survived the attempt' end,
                       v_success_chance, v_roll),
                'moon_destruction:' || p_battle_id::text);
        exception when others then
            raise warning 'MESSAGE_PRODUCER_FAILED moon_destruction=% error=%', p_battle_id, sqlerrm;
        end;
    end if;

    begin
        perform public.create_player_message(
            (select cb.attacker_player_id from public.combat_battles cb where cb.id = p_battle_id), null,
            case when v_destroyed then 'Moon destruction succeeded' else 'Moon destruction failed' end,
            format('Attempt on the moon at %s: chance %s%%, roll %s%s.',
                   public.format_coordinates(v_moon.galaxy, v_moon.system, v_moon.position),
                   v_success_chance, v_roll,
                   case when v_lost > 0 then format(', %s Deathstar(s) lost', v_lost) else '' end),
            'moon_destruction_attacker:' || p_battle_id::text);
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED moon_destruction=% error=%', p_battle_id, sqlerrm;
    end;

    return case when v_destroyed then 'DESTROYED' else 'SURVIVED' end;
exception when others then
    raise warning 'MOON_DESTRUCTION_FAILED battle=% error=%', p_battle_id, sqlerrm;
    return null;
end;
$function$;

comment on function public.settle_moon_destruction_for_battle(uuid) is
$c$Applies the OGameX moon-destruction outcome to a finished battle that carried at least one Deathstar against a moon:
success chance (100 − sqrt(diameter)) × sqrt(deathstars), deterministic roll, and the Deathstar loss chance
sqrt(diameter)/2 when the moon survives. A destroyed moon keeps its row (is_destroyed, relations intact), loses
ships/buildings/defences and leaves the debris of its fleet at the same coordinates. Logged in
moon_destruction_attempts (unique per battle). Failures only raise a WARNING so the combat path is never broken.$c$;

create or replace function public.on_combat_battle_finished_moon_destruction()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    perform public.settle_moon_destruction_for_battle(new.id);
    return new;
end;
$function$;

drop trigger if exists trg_on_combat_battle_finished_moon_destruction on public.combat_battles;
create trigger trg_on_combat_battle_finished_moon_destruction
    after update on public.combat_battles
    for each row
    when (old.finished_at is null and new.finished_at is not null)
    execute function public.on_combat_battle_finished_moon_destruction();

create or replace function public.on_combat_debris_moon_creation()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    perform public.settle_moon_creation_for_battle(new.battle_id);
    return new;
end;
$function$;

drop trigger if exists trg_on_combat_debris_moon_creation on public.combat_debris_generations;
create trigger trg_on_combat_debris_moon_creation
    after insert on public.combat_debris_generations
    for each row
    execute function public.on_combat_debris_moon_creation();

revoke all on function public.settle_moon_creation_for_battle(uuid) from public, anon, authenticated;
grant execute on function public.settle_moon_creation_for_battle(uuid) to service_role;
revoke all on function public.settle_moon_destruction_for_battle(uuid) from public, anon, authenticated;
grant execute on function public.settle_moon_destruction_for_battle(uuid) to service_role;
revoke all on function public.on_combat_debris_moon_creation() from public, anon, authenticated;
revoke all on function public.on_combat_battle_finished_moon_destruction() from public, anon, authenticated;

commit;

