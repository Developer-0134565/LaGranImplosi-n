-- ============================================================================
-- ESPIONAGE REPORT — BUILDINGS and RESEARCH sections (2026-09-27)
-- ----------------------------------------------------------------------------
-- Extends the certified espionage report with the two remaining OGameX categories. Until now LGI stored only
-- `fleet` (ships) and `defenses`; buildings and research were deliberately absent because the gating rule was not
-- implemented, which was recorded as a PRODUCT DECISION (README_ESPIONAGE_ENGINE §7/§10.1).
--
-- OGameX evidence, read verbatim at the pinned commit 7c420bad3478d7099791e1f33c920e9ff92822e8:
--
--   app/GameMissions/EspionageMission.php (processArrival):
--       $attackerEspionageLevel = $originPlayer->getResearchLevel('espionage_technology');
--       $defenderEspionageLevel = $targetPlayer->getResearchLevel('espionage_technology');
--       $levelDifference = max(0, $defenderEspionageLevel - $attackerEspionageLevel);
--       $extraProbesRequired = pow($levelDifference, 2);
--       $remainingProbes = max(0, $mission->espionage_probe - $extraProbesRequired);
--
--       if ($this->canRevealData($remainingProbes, $attacker, $defender, 2, 1)) $report->ships     = …
--       if ($this->canRevealData($remainingProbes, $attacker, $defender, 3, 2)) $report->defense   = …
--       if ($this->canRevealData($remainingProbes, $attacker, $defender, 5, 3)) $report->buildings = $targetPlanet->getBuildingArray();
--       if ($this->canRevealData($remainingProbes, $attacker, $defender, 7, 4)) $report->research  = $targetPlayer->getResearchArray();
--
--       private function canRevealData(int $remainingProbes, int $attackerLevel, int $defenderLevel,
--                                      int $probeThreshold, int $levelThreshold): bool
--       { return $remainingProbes >= $probeThreshold || $attackerLevel - $levelThreshold >= $defenderLevel; }
--
--   app/Models/EspionageReport.php: `buildings` and `research` are json columns (casts `array`), declared as
--   `array<string, int>` — machine-name -> level, exactly like `ships` / `defense`. OGameX keeps NO boolean
--   "revealed" flags: an absent section simply is not written.
--
-- ADAPTATION TO LGI (concept, not a copy)
--   * storage: `jsonb_object_agg(machine_name, level)` — buildings from `planet_buildings` of the TARGET body,
--     research from `player_research` of the TARGET OWNER. Same machine-name -> level shape as OGameX, and the same
--     shape as the certified `fleet` / `defenses` maps of this very report. LGI does not zero-fill absent
--     buildings/research the way OGameX's catalogue accessor may: the maps contain what the target actually has,
--     which is LGI's own state representation (a payload-shape detail with no gameplay effect).
--   * the two new thresholds are applied SERVER-SIDE at arrival, in the same statement that builds the report, so
--     the section is a snapshot exactly like ships/defence (a technology researched later never upgrades an old
--     report).
--   * the four reveal decisions are stored as boolean snapshot columns. The two older flags
--     (`ships_revealed` / `defenses_revealed`) were DERIVED at read time by `20260927120100`; they are now stored,
--     with a backfill that uses the very same expression, so every pre-existing row keeps the exact answer it had
--     (the migration asserts this equality for all rows). Unifying the four flags removes the mixed
--     derived/stored semantics that a second category would otherwise introduce.
--   * `buildings_revealed` / `research_revealed` default to FALSE on pre-existing rows: those rows genuinely have
--     no buildings/research payload, so "not revealed" is the honest answer (a derived flag would have claimed
--     "revealed" over an empty map).
--
-- Compatibility: the columns are APPENDED, the API answer only grows, ownership/`deny_direct_api_access`/the
-- 1..200 clamp/ACLs are untouched, and every pre-existing report keeps working with its stored values.
--
-- Verified by `supabase/tests/espionage_read_contract_reveal_flags.sql` (extended: buildings + research gating in
-- both directions, level path and probe path, cross-body isolation) plus the replayed `espionage_report_gating.sql`
-- and `counter_espionage.sql`.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. columns (appended; the table stays closed and read-only for clients)
-- ---------------------------------------------------------------------------
alter table public.espionage_reports
    add column if not exists buildings jsonb not null default '{}'::jsonb,
    add column if not exists research jsonb not null default '{}'::jsonb,
    add column if not exists ships_revealed boolean not null default false,
    add column if not exists defenses_revealed boolean not null default false,
    add column if not exists buildings_revealed boolean not null default false,
    add column if not exists research_revealed boolean not null default false;

comment on column public.espionage_reports.buildings is
$c$The target body's buildings as a machine-name -> level map, written at arrival ONLY when the OGameX rule reveals
the section (remaining probes >= 5 or attacker - 3 >= defender); '{}' otherwise.$c$;
comment on column public.espionage_reports.research is
$c$The target owner's research as a machine-name -> level map, written at arrival ONLY when the OGameX rule reveals
the section (remaining probes >= 7 or attacker - 4 >= defender); '{}' otherwise.$c$;
comment on column public.espionage_reports.ships_revealed is
$c$OGameX reveal decision for the ships section, stored at arrival (remaining >= 2 or attacker - 1 >= defender). For
rows created before 20260927130000 it was backfilled with the identical expression that 20260927120100 evaluated.$c$;
comment on column public.espionage_reports.defenses_revealed is
$c$OGameX reveal decision for the defence section, stored at arrival (remaining >= 3 or attacker - 2 >= defender). For
rows created before 20260927130000 it was backfilled with the identical expression that 20260927120100 evaluated.$c$;
comment on column public.espionage_reports.buildings_revealed is
$c$OGameX reveal decision for the buildings section, stored at arrival (remaining >= 5 or attacker - 3 >= defender).
Rows created before this migration carry FALSE: they have no buildings payload.$c$;
comment on column public.espionage_reports.research_revealed is
$c$OGameX reveal decision for the research section, stored at arrival (remaining >= 7 or attacker - 4 >= defender).
Rows created before this migration carry FALSE: they have no research payload.$c$;

/* Backfill the two pre-existing flags with the exact expression the read contract evaluated, so every old row keeps
   the answer it already had. The two new flags stay FALSE (no payload exists on those rows). */
update public.espionage_reports er
   set ships_revealed = (
         greatest(0, coalesce(er.probes_sent, 0)
                     - power(greatest(0, coalesce(er.target_espionage_level, 0) - coalesce(er.espionage_level, 0)), 2)) >= 2
         or (coalesce(er.espionage_level, 0) - 1) >= coalesce(er.target_espionage_level, 0)),
       defenses_revealed = (
         greatest(0, coalesce(er.probes_sent, 0)
                     - power(greatest(0, coalesce(er.target_espionage_level, 0) - coalesce(er.espionage_level, 0)), 2)) >= 3
         or (coalesce(er.espionage_level, 0) - 2) >= coalesce(er.target_espionage_level, 0));

-- ---------------------------------------------------------------------------
-- 2. the arrival resolver writes the two new sections and the four flags
--    Guarded catalogue patch: the installed body is read, every anchor must appear EXACTLY once, the patch is
--    idempotent, and the recreated definition must be byte-identical to the patched text. No other byte of the
--    resolver can drift (chance, battle, losses, debris, messages and transitions are untouched).
-- ---------------------------------------------------------------------------
do $patch$
declare
    v_fn    text := 'resolve_espionage_arrival';
    v_src   text;
    v_new   text;
    v_after text;
    v_a1 text;
    v_a2 text;
    v_a3 text;
    v_a4 text;
    v_a5 text;
begin
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_fn;

    if v_src is null then
        raise exception 'ESPIONAGE PATCH: % is missing', v_fn;
    end if;

    if position('v_reveal_buildings' in v_src) > 0 then
        raise notice 'ESPIONAGE PATCH: % already carries the new sections', v_fn;
        return;
    end if;

    /* A1 — declarations */
    v_a1 := '    v_reveal_ships boolean := true;' || chr(10) || '    v_reveal_defenses boolean := true;';
    /* A2 — the reveal computation (OGameX thresholds 5/3 and 7/4) */
    v_a2 := '    v_reveal_defenses := v_remaining >= 3 or (v_esp - 2) >= v_target_esp;';
    /* A3 — the insert column list */
    v_a3 := '        counter_espionage_chance, counter_espionage_triggered, probes_sent, probes_lost)';
    /* A4 — the select tail (the defence CASE close + the scalar tail) */
    v_a4 := '                else ''{}''::jsonb end,' || chr(10) ||
            '           v_chance, v_triggered, v_probes_sent, v_probes_lost';
    /* A5 — the ON CONFLICT update list */
    v_a5 := '            probes_lost = excluded.probes_lost';

    if (length(v_src) - length(replace(v_src, v_a1, ''))) <> length(v_a1)
       or (length(v_src) - length(replace(v_src, v_a2, ''))) <> length(v_a2)
       or (length(v_src) - length(replace(v_src, v_a3, ''))) <> length(v_a3)
       or (length(v_src) - length(replace(v_src, v_a4, ''))) <> length(v_a4)
       or (length(v_src) - length(replace(v_src, v_a5, ''))) <> length(v_a5) then
        raise exception 'ESPIONAGE PATCH: at least one anchor does not appear exactly once in %', v_fn;
    end if;

    v_new := replace(v_src, v_a1,
        '    v_reveal_ships boolean := true;' || chr(10) ||
        '    v_reveal_defenses boolean := true;' || chr(10) ||
        '    v_reveal_buildings boolean := true;' || chr(10) ||
        '    v_reveal_research boolean := true;');

    v_new := replace(v_new, v_a2,
        '    v_reveal_defenses := v_remaining >= 3 or (v_esp - 2) >= v_target_esp;' || chr(10) ||
        '    v_reveal_buildings := v_remaining >= 5 or (v_esp - 3) >= v_target_esp;' || chr(10) ||
        '    v_reveal_research := v_remaining >= 7 or (v_esp - 4) >= v_target_esp;');

    v_new := replace(v_new, v_a3,
        '        buildings, research, ships_revealed, defenses_revealed, buildings_revealed, research_revealed,' || chr(10) ||
        '        counter_espionage_chance, counter_espionage_triggered, probes_sent, probes_lost)');

    v_new := replace(v_new, v_a4,
        '                else ''{}''::jsonb end,' || chr(10) ||
        '           case when v_reveal_buildings' || chr(10) ||
        '                then coalesce((select jsonb_object_agg(pb.building_id, pb.level)' || chr(10) ||
        '                                 from public.planet_buildings pb' || chr(10) ||
        '                                where pb.planet_id = v_target.id), ''{}''::jsonb)' || chr(10) ||
        '                else ''{}''::jsonb end,' || chr(10) ||
        '           case when v_reveal_research and v_target.player_id is not null' || chr(10) ||
        '                then coalesce((select jsonb_object_agg(pr.research_id, pr.level)' || chr(10) ||
        '                                 from public.player_research pr' || chr(10) ||
        '                                where pr.player_id = v_target.player_id), ''{}''::jsonb)' || chr(10) ||
        '                else ''{}''::jsonb end,' || chr(10) ||
        '           v_reveal_ships, v_reveal_defenses, v_reveal_buildings, v_reveal_research,' || chr(10) ||
        '           v_chance, v_triggered, v_probes_sent, v_probes_lost');

    v_new := replace(v_new, v_a5,
        '            probes_lost = excluded.probes_lost,' || chr(10) ||
        '            buildings = excluded.buildings,' || chr(10) ||
        '            research = excluded.research,' || chr(10) ||
        '            ships_revealed = excluded.ships_revealed,' || chr(10) ||
        '            defenses_revealed = excluded.defenses_revealed,' || chr(10) ||
        '            buildings_revealed = excluded.buildings_revealed,' || chr(10) ||
        '            research_revealed = excluded.research_revealed');

    execute v_new;

    select pg_get_functiondef(p.oid) into v_after
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_fn;

    if v_after <> v_new then
        raise exception 'ESPIONAGE PATCH DRIFT: the recreated % differs from the patched source', v_fn;
    end if;

    raise notice 'ESPIONAGE PATCH: % now writes buildings, research and the four reveal flags', v_fn;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 2b. repair: an installation patched BEFORE this file was corrected carries the new columns AFTER the
--     counter-espionage names, which misaligns the positional INSERT (column 12 jsonb vs integer). The final order
--     is the one the SELECT produces: the four sections first, then the scalar tail. Idempotent: the wrong anchor
--     simply disappears once the order is right.
-- ---------------------------------------------------------------------------
do $repair$
declare
    v_wrong text := '        counter_espionage_chance, counter_espionage_triggered, probes_sent, probes_lost,' || chr(10) ||
                    '        buildings, research, ships_revealed, defenses_revealed, buildings_revealed, research_revealed)';
    v_right text := '        buildings, research, ships_revealed, defenses_revealed, buildings_revealed, research_revealed,' || chr(10) ||
                    '        counter_espionage_chance, counter_espionage_triggered, probes_sent, probes_lost)';
    v_src text;
    v_new text;
    v_after text;
begin
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'resolve_espionage_arrival';

    if v_src is null then
        raise exception 'ESPIONAGE REPAIR: resolve_espionage_arrival is missing';
    end if;
    if position(v_wrong in v_src) = 0 then
        raise notice 'ESPIONAGE REPAIR: not needed (column order already final)';
        return;
    end if;

    v_new := replace(v_src, v_wrong, v_right);
    execute v_new;

    select pg_get_functiondef(p.oid) into v_after
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'resolve_espionage_arrival';

    if v_after <> v_new then
        raise exception 'ESPIONAGE REPAIR DRIFT: the recreated resolver differs from the patched source';
    end if;

    raise notice 'ESPIONAGE REPAIR: INSERT column order corrected';
end;
$repair$;

-- ---------------------------------------------------------------------------
-- 3. the owner read contract returns the two new sections and the four flags
--    (same ownership chain, same clamp, same ACL; OUT parameters appended/grown, so the function is dropped first)
-- ---------------------------------------------------------------------------
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
    out_buildings jsonb,
    out_research jsonb,
    out_counter_espionage_chance integer,
    out_counter_espionage_triggered boolean,
    out_probes_sent bigint,
    out_probes_lost bigint,
    out_created_at timestamp with time zone,
    out_ships_revealed boolean,
    out_defenses_revealed boolean,
    out_buildings_revealed boolean,
    out_research_revealed boolean
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
           er.buildings,
           er.research,
           er.counter_espionage_chance,
           er.counter_espionage_triggered,
           er.probes_sent,
           er.probes_lost,
           er.created_at,
           er.ships_revealed,
           er.defenses_revealed,
           er.buildings_revealed,
           er.research_revealed
    from public.espionage_reports er
    left join public.planets p on p.id = er.target_planet_id
    where er.player_id in (select pl.id from public.players pl where pl.user_id = auth.uid())
    order by er.created_at desc, er.id
    limit greatest(1, least(coalesce(p_limit, 50), 200));
$function$;

comment on function public.get_player_espionage_reports(integer) is
$c$Client read contract for the caller's own espionage reports (a report belongs to the ATTACKER: player_id is the
fleet owner). Rows are selected strictly through auth.uid() -> players.user_id; no parameter selects a player or a
planet. Exposes the target coordinates and name, both espionage levels, resources, the four reveal-gated maps
(fleet, defenses, buildings, research) and the four reveal OUTCOMES stored at arrival
(out_ships_revealed / out_defenses_revealed / out_buildings_revealed / out_research_revealed), so the browser can
distinguish «not revealed» from «empty» without duplicating the OGameX rule. Limit clamped to 1..200.$c$;

revoke all on function public.get_player_espionage_reports(integer) from public, anon;
grant execute on function public.get_player_espionage_reports(integer) to authenticated;
grant execute on function public.get_player_espionage_reports(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 4. postconditions
-- ---------------------------------------------------------------------------
do $post$
declare
    v_cols integer;
    v_flags_mismatch integer;
    v_rows integer;
    v_resolver text;
    v_contract integer;
begin
    /* (a) the six columns exist with the expected shape */
    select count(*) into v_cols
      from information_schema.columns
     where table_schema = 'public' and table_name = 'espionage_reports'
       and (   (column_name in ('buildings', 'research') and data_type = 'jsonb' and column_default like '%{}%')
            or (column_name in ('ships_revealed', 'defenses_revealed', 'buildings_revealed', 'research_revealed')
                and data_type = 'boolean' and is_nullable = 'NO'));
    if v_cols <> 6 then
        raise exception 'POST: expected 6 new columns (2 jsonb + 4 boolean NOT NULL), found %', v_cols;
    end if;

    /* (b) the resolver carries the two OGameX thresholds verbatim and is still the only writer path */
    select prosrc into v_resolver
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'resolve_espionage_arrival';
    if v_resolver not like '%v_reveal_buildings := v_remaining >= 5 or (v_esp - 3) >= v_target_esp;%'
       or v_resolver not like '%v_reveal_research := v_remaining >= 7 or (v_esp - 4) >= v_target_esp;%'
       or v_resolver not like '%jsonb_object_agg(pb.building_id, pb.level)%'
       or v_resolver not like '%jsonb_object_agg(pr.research_id, pr.level)%'
       or v_resolver not like '%v_reveal_ships, v_reveal_defenses, v_reveal_buildings, v_reveal_research,%' then
        raise exception 'POST: resolve_espionage_arrival is missing part of the buildings/research patch';
    end if;

    /* (c) the backfill reproduced, for EVERY existing row, the answer 20260927120100 used to derive */
    select count(*) into v_rows from public.espionage_reports;
    select count(*) into v_flags_mismatch
      from public.espionage_reports er
     where er.ships_revealed is distinct from (
              greatest(0, coalesce(er.probes_sent, 0)
                          - power(greatest(0, coalesce(er.target_espionage_level, 0) - coalesce(er.espionage_level, 0)), 2)) >= 2
              or (coalesce(er.espionage_level, 0) - 1) >= coalesce(er.target_espionage_level, 0))
        or er.defenses_revealed is distinct from (
              greatest(0, coalesce(er.probes_sent, 0)
                          - power(greatest(0, coalesce(er.target_espionage_level, 0) - coalesce(er.espionage_level, 0)), 2)) >= 3
              or (coalesce(er.espionage_level, 0) - 2) >= coalesce(er.target_espionage_level, 0));
    if v_flags_mismatch <> 0 then
        raise exception 'POST: % of % rows carry a ships/defences flag that differs from the certified derivation',
            v_flags_mismatch, v_rows;
    end if;

    /* (d) the contract exposes all four sections and all four flags, owner-scoped, never anon */
    select count(*) into v_contract
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = 'get_player_espionage_reports'
       and pg_get_function_result(p.oid) like '%out_buildings jsonb%'
       and pg_get_function_result(p.oid) like '%out_research jsonb%'
       and pg_get_function_result(p.oid) like '%out_buildings_revealed boolean%'
       and pg_get_function_result(p.oid) like '%out_research_revealed boolean%'
       and pg_get_function_result(p.oid) like '%out_ships_revealed boolean%'
       and p.prosecdef;
    if v_contract <> 1 then
        raise exception 'POST: get_player_espionage_reports does not expose the four sections/flags';
    end if;
    if has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.get_player_espionage_reports(integer)', 'EXECUTE') then
        raise exception 'POST: get_player_espionage_reports ACL changed';
    end if;

    /* (e) the writer stays internal and the table stays closed with its single deny policy */
    if has_function_privilege('authenticated', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.resolve_espionage_arrival(uuid)', 'EXECUTE') then
        raise exception 'POST: resolve_espionage_arrival became client-reachable';
    end if;
    if (select count(*) from pg_policies
         where schemaname = 'public' and tablename = 'espionage_reports') <> 1
       or not exists (select 1 from pg_policies
                       where schemaname = 'public' and tablename = 'espionage_reports'
                         and policyname = 'deny_direct_api_access' and qual = 'false') then
        raise exception 'POST: espionage_reports lost its deny_direct_api_access closure';
    end if;
    if has_table_privilege('authenticated', 'public.espionage_reports', 'INSERT')
       or has_table_privilege('authenticated', 'public.espionage_reports', 'UPDATE') then
        raise exception 'POST: espionage_reports became writable by authenticated';
    end if;

    raise notice 'ESPIONAGE REPORT: buildings/research + 4 snapshot flags LIVE; % row(s) verified, 0 flag drift', v_rows;
end;
$post$;

commit;
