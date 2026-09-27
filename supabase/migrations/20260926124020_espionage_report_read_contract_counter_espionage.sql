-- ESPIONAGE READ CONTRACT — expose the counter-espionage columns (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- `20260926095835` added `get_player_espionage_reports` before counter-espionage existed. The contract must now
-- return the new fields, otherwise the browser can never show why a probe flight was detected or how many probes
-- were lost. The return type changes, so the function is dropped and recreated (PostgreSQL cannot change OUT
-- parameters with CREATE OR REPLACE) and the ACL is re-applied identically: authenticated/service_role only,
-- never anon. Ownership stays `er.player_id ∈ (players of auth.uid())`, p_limit clamped to 1..200, no parameter
-- selects a player or a planet.
begin;

drop function if exists public.get_player_espionage_reports(integer);

create or replace function public.get_player_espionage_reports(p_limit integer default 50)
returns table(
    out_report_id uuid,
    out_player_id uuid,
    out_fleet_id uuid,
    out_target_planet_id uuid,
    out_target_name text,
    out_galaxy integer,
    out_system integer,
    out_position integer,
    out_espionage_level integer,
    out_target_espionage_level integer,
    out_metal numeric,
    out_crystal numeric,
    out_deuterium numeric,
    out_energy numeric,
    out_fleet jsonb,
    out_defenses jsonb,
    out_counter_espionage_chance integer,
    out_counter_espionage_triggered boolean,
    out_probes_sent bigint,
    out_probes_lost bigint,
    out_created_at timestamp with time zone
)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select er.id,
           er.player_id,
           er.fleet_id,
           er.target_planet_id,
           p.name,
           p.galaxy,
           p.system,
           p.position,
           er.espionage_level,
           er.target_espionage_level,
           er.metal,
           er.crystal,
           er.deuterium,
           er.energy,
           er.fleet,
           er.defenses,
           er.counter_espionage_chance,
           er.counter_espionage_triggered,
           er.probes_sent,
           er.probes_lost,
           er.created_at
    from public.espionage_reports er
    left join public.planets p on p.id = er.target_planet_id
    where er.player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
    order by er.created_at desc, er.id
    limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

comment on function public.get_player_espionage_reports(integer) is
$c$Client read contract for the caller's own espionage reports (a report belongs to the ATTACKER: player_id is the
fleet owner). Rows are selected strictly through auth.uid() → players.user_id; no parameter selects a player or a
planet. Exposes the target coordinates and name, both espionage levels, resources, the (reveal-gated) fleet and
defence maps, and the counter-espionage outcome (chance, triggered, probes sent, probes lost). Limit clamped to
1..200. The contents of fleet/defenses are already gated by the OGameX reveal rule when the report is written.$c$;

revoke all on function public.get_player_espionage_reports(integer) from public, anon;
grant execute on function public.get_player_espionage_reports(integer) to authenticated;
grant execute on function public.get_player_espionage_reports(integer) to service_role;

commit;
