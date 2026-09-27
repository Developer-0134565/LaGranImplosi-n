-- ============================================================================
-- ESPIONAGE READ CONTRACT — expose the reveal OUTCOME, not just the gated maps (2026-09-27)
-- ----------------------------------------------------------------------------
-- FINDING: `20260926095835` + `20260926124020` certify a report whose `fleet` / `defenses` maps are ALREADY gated by
-- the OGameX reveal rule at write time (`resolve_espionage_arrival`):
--
--     remaining       = max(0, probes_sent - max(0, target_espionage_level - espionage_level) ^ 2)
--     reveal_ships    = remaining >= 2  or  espionage_level - 1 >= target_espionage_level
--     reveal_defenses = remaining >= 3  or  espionage_level - 2 >= target_espionage_level
--
-- When the rule denies the reveal the resolver stores `{}` — i.e. "not revealed" and "the planet has nothing" are
-- the SAME payload. The browser therefore cannot show the espionage-level gating that the server certifies without
-- re-implementing the rule client-side, which the project forbids (the frontend is never a second source of truth).
--
-- FIX (presentation metadata derived server-side from data ALREADY stored on the row): the contract returns
-- `out_ships_revealed` / `out_defenses_revealed`, computed with the very same expression the resolver used, from the
-- stored snapshot (`espionage_level`, `target_espionage_level`, `probes_sent`). No new rule, no new column, no
-- stored state: the outcome is a pure function of the row the resolver wrote, so it can never drift from it — and
-- because it reads the SNAPSHOT it also keeps the certified semantics that raising the attacker's technology later
-- does not upgrade an old report.
--
-- Ownership and ACL are unchanged: rows are still selected strictly through `auth.uid()` -> `players.user_id`,
-- `p_limit` is still clamped to 1..200, no parameter selects a player or a planet, `authenticated`/`service_role`
-- only (never `anon`). The function is dropped and recreated because PostgreSQL cannot change OUT parameters with
-- CREATE OR REPLACE.
--
-- Verified by `supabase/tests/espionage_read_contract_reveal_flags.sql` (and the existing
-- `espionage_report_gating.sql`, which still asserts the maps themselves).
-- ============================================================================
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
    out_created_at timestamp with time zone,
    out_ships_revealed boolean,
    out_defenses_revealed boolean
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
           er.created_at,
           /* OGameX EspionageMission::canRevealData, evaluated on the stored snapshot (ships: 2 probes / level - 1) */
           (greatest(0, coalesce(er.probes_sent, 0)
                        - power(greatest(0, coalesce(er.target_espionage_level, 0)
                                            - coalesce(er.espionage_level, 0)), 2)) >= 2
            or (coalesce(er.espionage_level, 0) - 1) >= coalesce(er.target_espionage_level, 0)),
           /* defence: 3 probes / level - 2 */
           (greatest(0, coalesce(er.probes_sent, 0)
                        - power(greatest(0, coalesce(er.target_espionage_level, 0)
                                            - coalesce(er.espionage_level, 0)), 2)) >= 3
            or (coalesce(er.espionage_level, 0) - 2) >= coalesce(er.target_espionage_level, 0))
    from public.espionage_reports er
    left join public.planets p on p.id = er.target_planet_id
    where er.player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
    order by er.created_at desc, er.id
    limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

comment on function public.get_player_espionage_reports(integer) is
$c$Client read contract for the caller's own espionage reports (a report belongs to the ATTACKER: player_id is the
fleet owner). Rows are selected strictly through auth.uid() -> players.user_id; no parameter selects a player or a
planet. Exposes the target coordinates and name, both espionage levels, resources, the reveal-gated fleet and defence
maps, the counter-espionage outcome (chance, triggered, probes sent, probes lost) and the reveal OUTCOME itself
(`out_ships_revealed` / `out_defenses_revealed`) so the browser can distinguish "not revealed" from "empty" without
duplicating the OGameX rule. Limit clamped to 1..200.$c$;

revoke all on function public.get_player_espionage_reports(integer) from public, anon;
grant execute on function public.get_player_espionage_reports(integer) to authenticated;
grant execute on function public.get_player_espionage_reports(integer) to service_role;

commit;