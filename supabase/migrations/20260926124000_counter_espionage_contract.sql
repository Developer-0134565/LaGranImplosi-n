-- COUNTER-ESPIONAGE — contract (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Product decision of the GAMEPLAY COMPLETION SWEEP: counter-espionage is ADOPTED — probes can be fought,
-- destroyed probes DO produce debris when the OGameX rule says so, the defender IS notified, and the espionage
-- report is gated by the OGameX reveal rule.
--
-- OGameX evidence read verbatim @ 7c420bad:
--   * `app/Services/CounterEspionageService.php`
--       chance% = floor(clamp(0..100, defender_ships × (defender_espionage − attacker_espionage + 1)
--                                          / (attacker_probes × 4) × 100))
--       0 when probes = 0, when the defender has no ships, or when the technology factor is <= 0
--       (attacker strictly ahead by 2+ levels);
--       the defender side is `getDefenderShipsForBattle()` = SHIPS only, defence structures do NOT participate.
--   * `app/GameMissions/EspionageMission.php:141-219`
--       triggered battle → `DebrisFieldService::appendResources($battleResult->debris)` at the TARGET planet
--       (so destroyed probes and destroyed defender ships DO create debris), a battle report for the DEFENDER,
--       a "fleet lost contact" message for the attacker whose probes died, and the espionage report is written
--       EVEN IF every probe is destroyed; the return leg only exists when something survived;
--       `canRevealData(remaining_probes, attacker, defender, probe_threshold, level_threshold)` with
--       remaining_probes = max(0, probes − max(0, defender_espionage − attacker_espionage)^2) and
--       reveal = remaining_probes >= probe_threshold OR attacker − level_threshold >= defender;
--       thresholds: ships (2, 1), defence (3, 2), buildings (5, 3), research (7, 4).
--       LGI reports carry ships and defence only (no building/research sections), so the last two thresholds have
--       no field to gate — documented, not invented. LGI buildings/research stay unreported, as before.
--
-- Replay safety: OGameX rolls with `random_int(1, 100)`. LGI must be replay-safe, so the roll uses the same
-- deterministic hash the expedition engine already uses (`expedition_event_random`), generalised here to
-- `fleet_event_random(fleet, stream, index)`: the value is a pure function of the fleet's immutable dispatch
-- timestamps, so re-running the resolver reproduces the same decision instead of re-rolling.
--
-- Certified by `supabase/tests/counter_espionage.sql`.
begin;

-- --------------------------------------------------------------------------- 1) report columns
alter table public.espionage_reports
    add column if not exists counter_espionage_chance integer,
    add column if not exists counter_espionage_triggered boolean,
    add column if not exists probes_sent bigint,
    add column if not exists probes_lost bigint;

comment on column public.espionage_reports.counter_espionage_chance is
$c$The counter-espionage chance (0..100) computed for this espionage flight with the OGameX formula. Stored even when
the roll did not trigger, exactly like OGameX stores it in the report.$c$;
comment on column public.espionage_reports.counter_espionage_triggered is
$c$True when the deterministic counter-espionage roll triggered a battle between the probes and the defender's ships.$c$;
comment on column public.espionage_reports.probes_sent is
$c$Number of espionage probes that arrived at the target.$c$;
comment on column public.espionage_reports.probes_lost is
$c$Probes destroyed by the counter-espionage battle (0 when no battle happened or every probe survived).$c$;

-- --------------------------------------------------------------------------- 2) deterministic randomness
create or replace function public.fleet_event_random(p_fleet_id uuid, p_stream text, p_index integer default 0)
returns numeric
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_started_at timestamp with time zone;
    v_arrives_at timestamp with time zone;
    v_hash integer;
    v_unsigned numeric;
begin
    select fm.started_at, fm.arrives_at
      into v_started_at, v_arrives_at
      from public.fleet_movements fm
     where fm.id = p_fleet_id;

    if v_started_at is null then
        raise exception 'Fleet % not found or has no dispatch timestamps', p_fleet_id;
    end if;

    v_hash := ('x' || substr(md5(p_fleet_id::text || '|' || v_started_at::text || '|' || v_arrives_at::text
                                 || '|' || coalesce(p_stream, '') || '|' || p_index::text), 1, 8))::bit(32)::int;
    v_unsigned := case when v_hash < 0 then v_hash::numeric + 4294967296 else v_hash::numeric end;

    return v_unsigned / 4294967296.0;
end;
$function$;

comment on function public.fleet_event_random(uuid, text, integer) is
$c$Deterministic, replay-safe randomness for fleet events: a pure function of the fleet's immutable dispatch
timestamps plus (stream, index). Mission-agnostic generalisation of `expedition_event_random` (which only accepts
EXPEDITION fleets and is left untouched). Returns a value in [0,1).$c$;

-- --------------------------------------------------------------------------- 3) the OGameX chance
create or replace function public.calculate_counter_espionage_chance(
    p_probe_count bigint,
    p_attacker_espionage_level integer,
    p_defender_espionage_level integer,
    p_defender_ship_count bigint
)
returns integer
language sql
immutable
as $function$
    select case
             when coalesce(p_probe_count, 0) <= 0 then 0
             when coalesce(p_defender_ship_count, 0) <= 0 then 0
             when (coalesce(p_defender_espionage_level, 0) - coalesce(p_attacker_espionage_level, 0) + 1) <= 0 then 0
             else least(100, greatest(0, floor(
                    (p_defender_ship_count
                     * (coalesce(p_defender_espionage_level, 0) - coalesce(p_attacker_espionage_level, 0) + 1))
                    / (p_probe_count * 4.0) * 100)))::integer
           end;
$function$;

comment on function public.calculate_counter_espionage_chance(bigint, integer, integer, bigint) is
$c$OGameX CounterEspionageService::calculateChance, transcribed verbatim: chance% = floor(clamp(0..100,
defender_ships × (defender_espionage − attacker_espionage + 1) / (probes × 4) × 100)), with 0 when there are no
probes, no defender ships, or the technology factor is <= 0. Defence structures never count (ships only).$c$;

create or replace function public.get_planet_defender_ship_count(p_planet_id uuid)
returns bigint
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select coalesce(sum(ps.quantity), 0)::bigint
    from public.planet_ships ps
    where ps.planet_id = p_planet_id;
$function$;

comment on function public.get_planet_defender_ship_count(uuid) is
$c$Total number of SHIPS on a planet (defence structures excluded), the defender count the counter-espionage chance
uses (OGameX CounterEspionageService::getDefenderShipCount).$c$;

revoke all on function public.fleet_event_random(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.fleet_event_random(uuid, text, integer) to service_role;

revoke all on function public.calculate_counter_espionage_chance(bigint, integer, integer, bigint)
    from public, anon, authenticated;
grant execute on function public.calculate_counter_espionage_chance(bigint, integer, integer, bigint)
    to service_role;

revoke all on function public.get_planet_defender_ship_count(uuid) from public, anon, authenticated;
grant execute on function public.get_planet_defender_ship_count(uuid) to service_role;

commit;
