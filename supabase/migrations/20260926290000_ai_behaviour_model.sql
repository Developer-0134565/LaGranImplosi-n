-- ============================================================================
-- AI BEHAVIOUR MODEL — LGI (owner-approved AI gameplay policy, 2026-09-26)
-- ----------------------------------------------------------------------------
-- OGameX @ 7c420bad has NO player-AI policy: its only NPC code (NPCFleetGeneratorService) builds
-- balanced ENEMY fleets for expedition battles. The behaviour policy is therefore LGI's own and
-- explicitly parameterised, and every rule the AI obeys when it ACTS is still a certified contract
-- (can_*/start_*, the AI service actor and the fleet engine). This migration introduces NO second rule
-- engine: it adds only the state and the deterministic helpers the policy needs.
--
--   * persistent personality per AI player (assigned once, stable);
--   * persistent planet specialisation + deterministic per-planet variation;
--   * deterministic daily activity windows: hash(player + UTC date) -> 3..6 h in 2..5 windows;
--   * deterministic rolls: same (player, kind, tick) -> same value, so a replayed tick is identical
--     (`random()` is deliberately NOT used by any AI decision);
--   * cooldown ranges per action family, weighted by personality;
--   * power estimation that REUSES the certified combat stat helpers (no formula duplication);
--   * espionage-driven target candidates + the probabilistic attack curve.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Persistent profiles (personality + cadence state, planet specialisation)
-- ---------------------------------------------------------------------------
create table if not exists public.ai_player_profiles (
    player_id        uuid primary key references public.players(id) on delete cascade,
    personality      text not null check (personality in ('INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR')),
    budget_percent   numeric not null default 60 check (budget_percent > 0 and budget_percent <= 100),
    last_action_at   timestamptz,
    last_action_kind text,
    next_action_at   timestamptz,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

create table if not exists public.ai_planet_profiles (
    planet_id  uuid primary key references public.planets(id) on delete cascade,
    template   text not null check (template in ('MINING_WORLD','RESEARCH_WORLD','MILITARY_WORLD','FLEET_BASE','EXPANSION_WORLD')),
    variation  numeric not null default 0 check (variation >= 0 and variation < 1),
    created_at timestamptz not null default now()
);

alter table public.ai_player_profiles enable row level security;
alter table public.ai_planet_profiles enable row level security;

revoke all on public.ai_player_profiles from public, anon, authenticated;
revoke all on public.ai_planet_profiles from public, anon, authenticated;
grant select, insert, update, delete on public.ai_player_profiles to service_role;
grant select, insert, update, delete on public.ai_planet_profiles to service_role;

drop policy if exists deny_direct_api_access on public.ai_player_profiles;
create policy deny_direct_api_access on public.ai_player_profiles
    for all to anon, authenticated using (false) with check (false);
drop policy if exists deny_direct_api_access on public.ai_planet_profiles;
create policy deny_direct_api_access on public.ai_planet_profiles
    for all to anon, authenticated using (false) with check (false);

-- ---------------------------------------------------------------------------
-- 2. Deterministic randomness + personality weights
-- ---------------------------------------------------------------------------
create or replace function public.ai_hash_unit(p_key text, p_seed bigint default 0)
returns numeric
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    /* Uniform value in [0,1) derived from the key. Stable across calls and replays. */
    select (((hashtextextended(p_key, p_seed) % 1000000) + 1000000) % 1000000)::numeric / 1000000;
$function$;

create or replace function public.ai_roll(p_player_id uuid, p_kind text, p_at timestamptz)
returns numeric
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    /* One deterministic roll per (player, kind, UTC minute). Replaying a tick reproduces it exactly. */
    select public.ai_hash_unit(
        p_player_id::text || '|' || p_kind || '|' ||
        to_char(coalesce(p_at, now()) at time zone 'utc', 'YYYYMMDDHH24MI'),
        88172645463325252);
$function$;

create or replace function public.ai_personality_weights(p_personality text)
returns table(economy numeric, research numeric, military numeric, espionage numeric)
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    /* Decision weights (not literal resource shares), owner-approved templates. */
    select t.e, t.r, t.m, t.s
      from (values
        ('INDUSTRIAL', 45::numeric, 25::numeric, 20::numeric, 10::numeric),
        ('SCIENTIST',  30::numeric, 40::numeric, 15::numeric, 15::numeric),
        ('MILITARY',   20::numeric, 25::numeric, 40::numeric, 15::numeric),
        ('PREDATOR',   20::numeric, 20::numeric, 35::numeric, 25::numeric)
      ) as t(p, e, r, m, s)
     where t.p = p_personality;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Personality profile (assigned once, then stable) + planet specialisation
-- ---------------------------------------------------------------------------
create or replace function public.ai_ensure_player_profile(p_player_id uuid)
returns table(player_id uuid, personality text, budget_percent numeric, last_action_at timestamptz,
              last_action_kind text, next_action_at timestamptz)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_is_ai boolean;
    v_personality text;
begin
    if p_player_id is null then
        raise exception 'AI_PROFILE_PLAYER_REQUIRED';
    end if;

    select (pl.player_type = 'AI' and pl.user_id is null) into v_is_ai
      from public.players pl where pl.id = p_player_id;
    if coalesce(v_is_ai, false) is not true then
        raise exception 'AI_PROFILE_TARGET_NOT_AI: %', p_player_id;
    end if;

    select app.personality into v_personality
      from public.ai_player_profiles app where app.player_id = p_player_id;

    if v_personality is null then
        v_personality := (array['INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR'])
                         [1 + floor(public.ai_hash_unit(p_player_id::text || '|personality', 5) * 4)::integer];
        insert into public.ai_player_profiles(player_id, personality)
        values (p_player_id, v_personality)
        on conflict (player_id) do nothing;
    end if;

    return query
    select app.player_id, app.personality, app.budget_percent, app.last_action_at, app.last_action_kind,
           app.next_action_at
      from public.ai_player_profiles app
     where app.player_id = p_player_id;
end;
$function$;

create or replace function public.ai_planet_profile(p_planet_id uuid)
returns table(template text, variation numeric)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_owner uuid;
    v_personality text;
    v_pref text[];
    v_template text;
    v_variation numeric;
begin
    select ap.template, ap.variation into v_template, v_variation
      from public.ai_planet_profiles ap where ap.planet_id = p_planet_id;
    if v_template is not null then
        template := v_template; variation := v_variation; return next; return;
    end if;

    select p.player_id into v_owner from public.planets p where p.id = p_planet_id;
    if v_owner is not null then
        select app.personality into v_personality
          from public.ai_player_profiles app where app.player_id = v_owner;
    end if;

    /* Personality bias first, per-planet hash second: an industrial AI does not specialise like a predator. */
    v_pref := case coalesce(v_personality, 'INDUSTRIAL')
        when 'INDUSTRIAL' then array['MINING_WORLD','EXPANSION_WORLD','MINING_WORLD']
        when 'SCIENTIST'  then array['RESEARCH_WORLD','MINING_WORLD','RESEARCH_WORLD']
        when 'MILITARY'   then array['MILITARY_WORLD','FLEET_BASE','MINING_WORLD']
        else                   array['FLEET_BASE','MILITARY_WORLD','EXPANSION_WORLD']
    end;

    v_template := v_pref[1 + floor(public.ai_hash_unit(p_planet_id::text || '|template', 53)
                                   * array_length(v_pref, 1))::integer];
    v_variation := round(public.ai_hash_unit(p_planet_id::text || '|variation', 59), 4);

    insert into public.ai_planet_profiles(planet_id, template, variation)
    values (p_planet_id, v_template, v_variation)
    on conflict (planet_id) do nothing;

    select ap.template, ap.variation into v_template, v_variation
      from public.ai_planet_profiles ap where ap.planet_id = p_planet_id;
    template := v_template; variation := v_variation; return next;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. Daily activity windows (3..6 h per UTC day in 2..5 windows), cooldown and score
-- ---------------------------------------------------------------------------
create or replace function public.ai_daily_activity(p_player_id uuid, p_date date)
returns table(window_index integer, start_minute integer, end_minute integer)
language plpgsql
immutable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_key text := p_player_id::text || '|' || p_date::text;
    v_total integer;
    v_windows integer;
    v_gap0 integer;
    v_gap_base integer;
    v_gap_rem integer;
    v_pos integer;
    v_len integer;
    v_i integer;
begin
    v_total   := 180 + floor(public.ai_hash_unit(v_key, 11) * 181)::integer;   /* 180..360 min = 3..6 h */
    v_windows := 2 + floor(public.ai_hash_unit(v_key, 23) * 4)::integer;       /* 2..5 ventanas */
    v_gap0    := 120 + floor(public.ai_hash_unit(v_key, 37) * 401)::integer;   /* 2 h .. 8.7 h de descanso */
    v_gap_base := (1440 - v_total - v_gap0) / v_windows;
    v_gap_rem  := (1440 - v_total - v_gap0) % v_windows;

    v_pos := v_gap0;
    for v_i in 1..v_windows loop
        v_len := v_total / v_windows + (case when v_i <= (v_total % v_windows) then 1 else 0 end);
        window_index := v_i;
        start_minute := v_pos;
        end_minute := v_pos + v_len;
        return next;
        v_pos := v_pos + v_len + v_gap_base + (case when v_i = v_windows then v_gap_rem else 0 end);
    end loop;
end;
$function$;

create or replace function public.ai_is_active_at(p_player_id uuid, p_at timestamptz default now())
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    select exists (
        select 1
          from public.ai_daily_activity(p_player_id, (coalesce(p_at, now()) at time zone 'utc')::date) w
         where (extract(hour from (coalesce(p_at, now()) at time zone 'utc')) * 60
                + extract(minute from (coalesce(p_at, now()) at time zone 'utc')))::integer
               between w.start_minute and w.end_minute - 1
    );
$function$;

create or replace function public.ai_cooldown_minutes(p_kind text, p_personality text, p_roll numeric)
returns integer
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    with rng as (
        select case p_kind
                 when 'building'     then array[10, 35]
                 when 'research'     then array[30, 120]
                 when 'production'   then array[20, 90]   /* shipyard/defence: the documented fleet range */
                 when 'fleet'        then array[20, 90]
                 when 'espionage'    then array[15, 60]
                 when 'attack'       then array[45, 180]
                 when 'colonization' then array[120, 360]
                 else array[15, 60]
               end as r
    ), weighted as (
        select r, case
            when p_personality in ('MILITARY','PREDATOR') and p_kind in ('fleet','attack','espionage') then 0.70
            when p_personality = 'PREDATOR' and p_kind in ('building','research') then 1.15
            when p_personality = 'SCIENTIST' and p_kind = 'research' then 0.75
            when p_personality = 'SCIENTIST' and p_kind in ('fleet','attack') then 1.30
            when p_personality = 'INDUSTRIAL' and p_kind in ('building','colonization') then 0.80
            when p_personality = 'INDUSTRIAL' and p_kind = 'attack' then 1.25
            else 1.00
        end as factor
        from rng
    )
    select greatest(1, round((r[1] + (r[2] - r[1]) * least(greatest(coalesce(p_roll, 0.5), 0), 1)) * factor)::integer)
      from weighted;
$function$;

create or replace function public.ai_score(p_weight numeric, p_affordable boolean, p_need numeric, p_roll numeric)
returns numeric
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    /* score = template weight x affordability x strategic need x random(0.80..1.20) */
    select case
             when coalesce(p_affordable, false) is not true
               or p_weight is null or p_weight <= 0
               or p_need is null or p_need <= 0 then 0::numeric
             else round(p_weight * p_need
                        * (0.80 + 0.40 * least(greatest(coalesce(p_roll, 0.5), 0), 1)), 6)
           end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Power estimation (REUSES the certified combat stat helpers) + knowledge from reports
-- ---------------------------------------------------------------------------
create or replace function public.ai_composition_power(p_ships jsonb, p_defenses jsonb, p_player_id uuid default null)
returns numeric
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_power numeric := 0;
    v_unit record;
    v_qty numeric;
    v_a numeric; v_s numeric; v_h numeric;
begin
    /* p_player_id known -> certified helpers (real weapons/shielding/armour levels).
       p_player_id null  -> the definitions' base stats plus a conservative 1.15 factor, because an LGI
       espionage report carries no research; the factor is the documented uncertainty allowance. */
    for v_unit in select key as id, (value #>> '{}')::numeric as qty
                    from jsonb_each(coalesce(p_ships, '{}'::jsonb)) loop
        v_qty := coalesce(v_unit.qty, 0);
        if v_qty <= 0 then continue; end if;
        if p_player_id is null then
            select sd.attack, sd.shield, sd.hull into v_a, v_s, v_h
              from public.ship_definitions sd where sd.id = v_unit.id;
            v_power := v_power + v_qty * (coalesce(v_a,0) + coalesce(v_s,0) + coalesce(v_h,0)) * 1.15;
        else
            v_power := v_power + v_qty * (
                  coalesce(public.get_combat_ship_attack(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_ship_shield(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_ship_hull(p_player_id, v_unit.id), 0));
        end if;
    end loop;

    for v_unit in select key as id, (value #>> '{}')::numeric as qty
                    from jsonb_each(coalesce(p_defenses, '{}'::jsonb)) loop
        v_qty := coalesce(v_unit.qty, 0);
        if v_qty <= 0 then continue; end if;
        if p_player_id is null then
            select dd.attack, dd.shield, dd.hull into v_a, v_s, v_h
              from public.defense_definitions dd where dd.id = v_unit.id;
            v_power := v_power + v_qty * (coalesce(v_a,0) + coalesce(v_s,0) + coalesce(v_h,0)) * 1.15;
        else
            v_power := v_power + v_qty * (
                  coalesce(public.get_combat_defense_attack(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_defense_shield(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_defense_hull(p_player_id, v_unit.id), 0));
        end if;
    end loop;

    return round(v_power, 2);
end;
$function$;

create or replace function public.ai_known_target_power(p_player_id uuid, p_target_planet_id uuid)
returns table(known boolean, report_id uuid, reported_at timestamptz, ships jsonb, defenses jsonb, power numeric)
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_report public.espionage_reports%rowtype;
begin
    select er.* into v_report
      from public.espionage_reports er
     where er.player_id = p_player_id and er.target_planet_id = p_target_planet_id
     order by er.created_at desc, er.id
     limit 1;

    if not found then
        known := false; report_id := null; reported_at := null;
        ships := null; defenses := null; power := null;
        return next; return;
    end if;

    /* LGI reports reveal ships (2/1) and defences (3/2) only when the certified reveal gate allowed it.
       Without that data the AI has NO information about the target and must not guess a strength. */
    if v_report.fleet is null and v_report.defenses is null then
        known := false; report_id := v_report.id; reported_at := v_report.created_at;
        ships := null; defenses := null; power := null;
        return next; return;
    end if;

    known := true;
    report_id := v_report.id;
    reported_at := v_report.created_at;
    ships := coalesce(v_report.fleet, '{}'::jsonb);
    defenses := coalesce(v_report.defenses, '{}'::jsonb);
    power := public.ai_composition_power(ships, defenses, null);
    return next;
end;
$function$;

create or replace function public.ai_attack_probability(p_relative numeric, p_personality text)
returns numeric
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    /* Owner-approved zones, NOT an absolute rule: the personality scales the probability and the caller
       still rolls. Bounded by 0.85 so no attack is ever certain. */
    select least(0.85, greatest(0::numeric, case
             when p_relative is null then 0::numeric
             when p_relative < 0.75 then 0.02
             when p_relative < 0.95 then 0.15
             when p_relative < 1.25 then 0.35
             else 0.60
           end * case p_personality
                   when 'PREDATOR'  then 1.30
                   when 'MILITARY'  then 1.10
                   when 'SCIENTIST' then 0.70
                   else 0.50
                 end));
$function$;

-- ---------------------------------------------------------------------------
-- 6. Target candidates (proximity first, never merely the nearest) + unit doctrine
-- ---------------------------------------------------------------------------
create or replace function public.ai_espionage_candidates(p_player_id uuid, p_origin_planet_id uuid,
                                                          p_limit integer default 5)
returns table(target_planet_id uuid, target_player_id uuid, distance numeric, score numeric)
language sql
stable
set search_path to 'public', 'pg_temp'
as $function$
    with origin as (
        select p.universe_id from public.planets p where p.id = p_origin_planet_id
    ), cand as (
        select tp.id, tp.player_id as pid,
               public.calculate_fleet_distance_to_coordinates(
                   p_origin_planet_id, tp.galaxy, tp.system, tp.position) as dist
          from public.planets tp
          join origin o on o.universe_id = tp.universe_id
         where not tp.is_destroyed
           and tp.player_id is not null
           and tp.player_id <> p_player_id
    )
    select c.id, c.pid, c.dist,
           round((1000 / (100 + c.dist))
                 * (0.70 + 0.60 * public.ai_hash_unit(p_player_id::text || '|spy|' || c.id::text, 71)), 6)
      from cand c
     order by 4 desc, c.dist, c.id
     limit greatest(1, least(coalesce(p_limit, 5), 20));
$function$;

create or replace function public.ai_attack_candidates(p_player_id uuid, p_origin_planet_id uuid,
                                                       p_budget_percent numeric default 60,
                                                       p_limit integer default 5)
returns table(target_planet_id uuid, target_player_id uuid, distance numeric,
              target_power numeric, own_power numeric, relative_power numeric, report_age_seconds numeric)
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_own jsonb;
    v_sendable numeric;
    v_cand record;
    v_report record;
    v_seen integer := 0;
begin
    /* Sendable attack power: the AI's warships on the origin, limited by the budget share of the action. */
    select coalesce(jsonb_object_agg(ps.ship_id, ps.quantity), '{}'::jsonb) into v_own
      from public.planet_ships ps
      join public.ship_definitions sd on sd.id = ps.ship_id
     where ps.planet_id = p_origin_planet_id and ps.quantity > 0 and sd.ship_type = 'combat';
    v_sendable := round(public.ai_composition_power(v_own, '{}'::jsonb, p_player_id)
                        * least(greatest(coalesce(p_budget_percent, 60), 1), 100) / 100, 2);

    for v_cand in select * from public.ai_espionage_candidates(p_player_id, p_origin_planet_id, 20) loop
        select * into v_report from public.ai_known_target_power(p_player_id, v_cand.target_planet_id);
        if coalesce(v_report.known, false) is not true or coalesce(v_report.power, 0) <= 0 then
            continue;   /* no espionage information -> the AI does not guess a strength */
        end if;

        target_planet_id := v_cand.target_planet_id;
        target_player_id := v_cand.target_player_id;
        distance := v_cand.distance;
        target_power := v_report.power;
        own_power := v_sendable;
        relative_power := round(v_sendable / v_report.power, 4);
        report_age_seconds := round(extract(epoch from (now() - v_report.reported_at)), 0);
        return next;

        v_seen := v_seen + 1;
        exit when v_seen >= greatest(1, least(coalesce(p_limit, 5), 20));
    end loop;
end;
$function$;

create or replace function public.ai_unit_preference(p_kind text, p_personality text, p_template text)
returns text[]
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
    /* Doctrine per personality + planet template (ships and defences that LGI actually defines). */
    select case p_kind
      when 'SHIP' then
        case
          when p_personality = 'PREDATOR' then
            case when p_template in ('FLEET_BASE','MILITARY_WORLD')
                 then array['light_fighter','heavy_fighter','cruiser','battleship','espionage_probe']
                 else array['espionage_probe','light_fighter','small_cargo'] end
          when p_personality = 'MILITARY' then
            case when p_template in ('MILITARY_WORLD','FLEET_BASE')
                 then array['light_fighter','heavy_fighter','cruiser','battleship','destroyer']
                 else array['small_cargo','light_fighter'] end
          when p_personality = 'SCIENTIST' then array['espionage_probe','small_cargo','recycler']
          else array['small_cargo','large_cargo','recycler']
        end
      when 'DEFENSE' then
        case
          when p_personality in ('MILITARY','PREDATOR')
            then array['rocket_launcher','light_laser','heavy_laser','ion_cannon','gauss_cannon','small_shield_dome']
          when p_personality = 'SCIENTIST' then array['rocket_launcher','light_laser']
          else array['rocket_launcher','light_laser','heavy_laser']
        end
      else array[]::text[]
    end;
$function$;

create or replace function public.ai_pick_unit(p_player_id uuid, p_planet_id uuid, p_kind text,
                                               p_personality text, p_template text,
                                               p_budget_percent numeric, p_roll numeric)
returns text
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_prefs text[] := public.ai_unit_preference(p_kind, p_personality, p_template);
    v_len integer;
    v_res record;
    v_can record;
    v_idx integer;
    v_i integer;
    v_id text;
begin
    v_len := coalesce(array_length(v_prefs, 1), 0);
    if v_len = 0 then
        return null;
    end if;

    select * into v_res from public.planet_resources pr where pr.planet_id = p_planet_id;

    v_idx := 1 + floor(least(greatest(coalesce(p_roll, 0.5), 0), 1) * v_len)::integer;
    if v_idx > v_len then v_idx := v_len; end if;

    /* Rotate the doctrine so the whole preference list is used over time, then take the first candidate
       that the CERTIFIED availability contract allows and that the budget can pay. */
    for v_i in 0..v_len - 1 loop
        v_id := v_prefs[1 + ((v_idx - 1 + v_i) % v_len)];
        if p_kind = 'SHIP' then
            select * into v_can from public.can_build_ship(p_player_id, p_planet_id, v_id, 1) limit 1;
        else
            select * into v_can from public.can_build_defense(p_player_id, p_planet_id, v_id, 1) limit 1;
        end if;

        if coalesce(v_can.allowed, false)
           and coalesce(v_can.metal_cost, 0) <= coalesce(v_res.metal, 0) * p_budget_percent / 100
           and coalesce(v_can.crystal_cost, 0) <= coalesce(v_res.crystal, 0) * p_budget_percent / 100
           and coalesce(v_can.deuterium_cost, 0) <= greatest(0, coalesce(v_res.deuterium, 0) - 1000)
                                                    * p_budget_percent / 100
        then
            return v_id;
        end if;
    end loop;

    return null;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 7. ACL: the whole model is internal (the AI runs as a declared service actor)
-- ---------------------------------------------------------------------------
do $ai_model_acl$
declare
    v_fn text;
begin
    for v_fn in
        select p.oid::regprocedure::text
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname like 'ai!_%' escape '!'
    loop
        execute format('revoke all on function %s from public, anon, authenticated', v_fn);
        execute format('grant execute on function %s to service_role', v_fn);
    end loop;
end;
$ai_model_acl$;