-- =====================================================================
-- DEDICATED MOON DESTRUCTION MISSION — LGI ↔ OGameX (owner-approved 2026-09-26)
-- =====================================================================
-- OGameX reference (structural):
--   app/GameMissions/MoonDestructionMission.php :: `extends GameMission`, `$fleetSpeedType = FleetSpeedType::war`,
--       isMissionPossible → "Moon Destruction requires at least one Deathstar.", target must be a foreign moon,
--       and the outcome is decided AFTER the battle (calculateMoonDestructionChance =
--       (100 − √diameter)·√deathstars, deathstar loss chance = √diameter/2).
--
-- LGI integration (no duplication of the certified outcome logic):
--   * `fleet_movements.mission_type` accepts the new value (CHECK extended, original values untouched).
--   * `calculate_mission_fleet_speed_multiplier` classifies it as a WAR mission (OGameX FleetSpeedType::war).
--   * `start_moon_destruction(player, origin, destination, ships)` validates the OGameX requirements
--     (≥ 1 deathstar, destination is a foreign, alive moon) and delegates to the certified dispatch
--     `start_fleet_mixed` (fuel, distance, fleet rows), so there is a single dispatch authority.
--   * `resolve_attack_arrival` accepts the new mission type and its attacker-return query includes it, so the
--     fleet is resolved and returned exactly like an attack.
--   * `process_fleet_movements` routes the new mission to the same resolver — the destruction roll is NOT
--     re-implemented: the certified hook `on_combat_battle_finished_moon_destruction` →
--     `settle_moon_destruction_for_battle(battle_id)` keeps applying the OGameX rules (idempotent per battle).
-- =====================================================================

alter table public.fleet_movements drop constraint if exists fleet_movements_mission_type_check;
alter table public.fleet_movements add constraint fleet_movements_mission_type_check check (
    mission_type = any (array[
        'ATTACK', 'TRANSPORT', 'DEPLOY', 'ESPIONAGE', 'COLONIZE', 'RECYCLE',
        'EXPEDITION', 'ACS_HOLD', 'HOLDING', 'DEFEND', 'MOON_DESTRUCTION'
    ])
);

-- ---------------------------------------------------------------------
-- Classifier + dispatch whitelist (OGameX: FleetSpeedType::war).
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'calculate_mission_fleet_speed_multiplier';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: calculate_mission_fleet_speed_multiplier';
    end if;
    if position('MOON_DESTRUCTION' in v_src) > 0 then
        return;
    end if;

    v_old := 'WHEN v_mission IN (''ATTACK'',''ESPIONAGE'',''RECYCLE'',''RECYCLE_ATTACK'',''HARVEST'') THEN war_fleet_speed';
    v_new := 'WHEN v_mission IN (''ATTACK'',''ESPIONAGE'',''RECYCLE'',''RECYCLE_ATTACK'',''HARVEST'',''MOON_DESTRUCTION'') THEN war_fleet_speed';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: classifier war group';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_fleet_mixed';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: start_fleet_mixed';
    end if;
    if position('MOON_DESTRUCTION' in v_src) > 0 then
        return;
    end if;

    v_old := 'IF v_mission_type NOT IN (''ATTACK'',''TRANSPORT'',''DEPLOY'',''ESPIONAGE'',''RECYCLE'',''EXPEDITION'') THEN';
    v_new := 'IF v_mission_type NOT IN (''ATTACK'',''TRANSPORT'',''DEPLOY'',''ESPIONAGE'',''RECYCLE'',''EXPEDITION'',''MOON_DESTRUCTION'') THEN';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: start_fleet_mixed mission whitelist';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ---------------------------------------------------------------------
-- Dispatcher. OGameX isMissionPossible + single dispatch authority (start_fleet_mixed).
-- ---------------------------------------------------------------------
create or replace function public.start_moon_destruction(
    p_player_id uuid,
    p_origin_planet_id uuid,
    p_destination_planet_id uuid,
    p_ships jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_auth_user uuid := auth.uid();
    v_target public.planets%rowtype;
    v_deathstars bigint := 0;
    v_fleet_id uuid;
begin
    /* identity: owner session or the certified AI service actor */
    if v_auth_user is not null and not exists (
        select 1 from public.players pl where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
        raise exception 'Player does not belong to authenticated user';
    elsif v_auth_user is null and not public.is_ai_actor_target(p_player_id) then
        raise exception 'Authentication required';
    end if;

    /* OGameX: the target must be a moon, alive, and not the player's own */
    select * into v_target from public.planets p where p.id = p_destination_planet_id;
    if not found then
        raise exception 'MOON_DESTRUCTION_TARGET_NOT_FOUND: %', p_destination_planet_id;
    end if;
    if v_target.kind <> 'MOON' then
        raise exception 'MOON_DESTRUCTION_TARGET_NOT_A_MOON: %', p_destination_planet_id;
    end if;
    if v_target.is_destroyed then
        raise exception 'MOON_DESTRUCTION_TARGET_DESTROYED: %', p_destination_planet_id;
    end if;
    if v_target.player_id = p_player_id then
        raise exception 'MOON_DESTRUCTION_TARGET_OWN: %', p_destination_planet_id;
    end if;

    /* composition shape is { '<ship_id>': <quantity> } — scalar extraction with #>> '{}' */
    select coalesce(sum((value #>> '{}')::bigint), 0) into v_deathstars
    from jsonb_each(coalesce(p_ships, '{}'::jsonb))
    where key = 'deathstar';

    if v_deathstars < 1 then
        raise exception 'MOON_DESTRUCTION_DEATHSTAR_REQUIRED';
    end if;

    /* certified dispatch (fuel, distance, fleet rows, war speed class) */
    select fm.fleet_id into v_fleet_id
    from public.start_fleet_mixed(p_player_id, p_origin_planet_id, p_destination_planet_id,
                                  p_ships, 'MOON_DESTRUCTION') fm
    limit 1;

    return v_fleet_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- The attack resolver accepts the new mission (the combat engine and the certified
-- moon-destruction hook stay untouched).
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resolve_attack_arrival';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: resolve_attack_arrival';
    end if;

    v_old := 'if v_fleet.mission_type<>''ATTACK'' then raise exception ''Fleet % no es ATTACK'',p_fleet_id; end if;';
    v_new := 'if v_fleet.mission_type not in (''ATTACK'',''MOON_DESTRUCTION'') then raise exception ''Fleet % no es ATTACK'',p_fleet_id; end if;';

    if position(v_old in v_src) = 0 then
        if position('MOON_DESTRUCTION' in v_src) > 0 then
            return;
        end if;
        raise exception 'PATCH ANCHOR NOT FOUND: resolve_attack_arrival mission guard';
    end if;
    v_src := replace(v_src, v_old, v_new);

    v_old := 'and status=''ARRIVED'' and mission_type=''ATTACK'';';
    v_new := 'and status=''ARRIVED'' and mission_type in (''ATTACK'',''MOON_DESTRUCTION'');';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: resolve_attack_arrival attacker return query';
    end if;

    execute replace(v_src, v_old, v_new);
end;
$patch$;

do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'process_fleet_movements';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: process_fleet_movements';
    end if;
    if position('MOON_DESTRUCTION' in v_src) > 0 then
        return;
    end if;

    v_old := 'elsif v.mission_type=''ATTACK'' then';
    v_new := 'elsif v.mission_type in (''ATTACK'',''MOON_DESTRUCTION'') then';

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: process_fleet_movements attack branch';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

revoke all on function public.start_moon_destruction(uuid, uuid, uuid, jsonb) from public;
grant execute on function public.start_moon_destruction(uuid, uuid, uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- LATENT-CERTIFIED-DEFECT FIX 1/2 — start_fleet_mixed() ship deduction.
-- `UPDATE public.planet_ships SET quantity=quantity-v_quantity ... AND ship_id=v_ship_id` resolves
-- `ship_id` ambiguously against the function's OUT parameter of the same name, so any mixed dispatch that
-- reaches the deduction raises `column reference "ship_id" is ambiguous`. Qualified with an alias.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'start_fleet_mixed';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: start_fleet_mixed';
    end if;

    v_old := 'UPDATE public.planet_ships SET quantity=quantity-v_quantity WHERE planet_id=p_origin_planet_id AND ship_id=v_ship_id;';
    v_new := 'UPDATE public.planet_ships ps SET quantity = ps.quantity - v_quantity WHERE ps.planet_id = p_origin_planet_id AND ps.ship_id = v_ship_id;';

    if position(v_old in v_src) = 0 then
        if position('UPDATE public.planet_ships ps SET quantity = ps.quantity - v_quantity' in v_src) > 0 then
            return;
        end if;
        raise exception 'PATCH ANCHOR NOT FOUND: start_fleet_mixed ship deduction';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;

-- ---------------------------------------------------------------------
-- LATENT-CERTIFIED-DEFECT FIX 2/2 — resolve_combat() mission guard.
-- The combat engine carried a second, Spanish-worded ATTACK-only guard
-- (`mission_type <> 'ATTACK' then raise exception 'Fleet % no es una misión ATTACK'`), so the
-- MOON_DESTRUCTION fleet resolved by resolve_attack_arrival was rejected one level deeper.
-- The outcome rules are untouched: only the accepted mission set is widened.
-- ---------------------------------------------------------------------
do $patch$
declare
    v_src text;
    v_old text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'resolve_combat';

    if v_src is null then
        raise exception 'PATCH TARGET MISSING: resolve_combat';
    end if;
    if position('MOON_DESTRUCTION' in v_src) > 0 then
        return;
    end if;

    v_old := $q$mission_type <> 'ATTACK' then raise exception 'Fleet % no es una misión ATTACK'$q$;
    v_new := $q$mission_type not in ('ATTACK','MOON_DESTRUCTION') then raise exception 'Fleet % no es una misión ATTACK'$q$;

    if position(v_old in v_src) = 0 then
        raise exception 'PATCH ANCHOR NOT FOUND: resolve_combat mission guard';
    end if;
    execute replace(v_src, v_old, v_new);
end;
$patch$;
