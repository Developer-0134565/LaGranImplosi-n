-- ============================================================================================
-- ESPIONAGE MISSION COMPOSITION RULE — the mission may only carry espionage probes
-- ============================================================================================
-- GAP (2026-09-28, Gameplay gap cycle). The full espionage cycle was already certified end to end
-- (dispatch -> resolve_espionage_arrival -> espionage_reports -> get_player_espionage_reports ->
-- EspionageReportsPanel), so this is NOT a re-opening of that work. It is a single missing INVARIANT
-- on the dispatch path, and it was measured LIVE before anything was changed:
--
--   * `start_fleet_mixed` and `start_fleet` enforce the composition rule for RECYCLE
--     ("RECYCLE mixed fleet may contain only recyclers" / "RECYCLE mission requires recycler")
--     but enforce NOTHING for ESPIONAGE. Any ship may be sent.
--   * A fleet of three light_fighters on an ESPIONAGE mission was ACCEPTED, persisted as a
--     fleet_movements row, charged fuel and consumed a fleet slot.
--   * On arrival the authoritative resolver produced a report with probes_sent = 0,
--     counter_espionage_chance = 0 and all four reveal flags false — i.e. a report that is
--     STRUCTURALLY GUARANTEED to reveal nothing, at full cost. A message was still produced.
--
-- The defect is internal, not a security hole: the player only harms their own empire. But it is a
-- real gameplay gap, because the resolver derives EVERYTHING from espionage_probe:
--   * probes_sent  = SUM(quantity) WHERE ship_id = 'espionage_probe'
--   * the counter-espionage chance is 0 whenever probe_count <= 0
--   * the whole reveal ladder (OGameX) is driven by max(0, probes_sent - level_gap^2)
-- so a probe-less espionage flight can never reveal ships, defences, buildings or research.
--
-- FIX: mirror the existing, already-certified RECYCLE rule for ESPIONAGE, in the same place and in
-- the same style, inside the SAME composition loop of `start_fleet_mixed` (so it raises before any
-- resource is touched) and in the single-ship guard of `start_fleet`.
--
-- Deliberately NOT changed: the resolver, the reveal rule, the level gating, the report contract, the
-- ACL, the fleet engine, the mission lifecycle. Nothing else about espionage moves.
-- ============================================================================================

-- The two dispatch contracts are long, fully-certified bodies. Rather than retyping them here (a
-- transcription drift in a function nobody should be touching would be invisible), the guard is
-- inserted into the CURRENT source through an anchor that must be present EXACTLY ONCE, or the
-- migration aborts without changing anything. Every other line of both functions stays byte-identical.
--
-- The `DEFAULT 'TRANSPORT'` on p_mission_type is REPEATED on purpose: `create or replace` refuses to
-- drop an existing parameter default (42P13), so the live default must be carried over verbatim.

do $patch$
declare
    v_oid oid;
    v_body text;
    v_anchor text;
    v_occurrences integer;
begin
    /* ---------------- start_fleet_mixed: the guard joins the composition loop ---------------- */
    v_anchor := $$IF v_mission_type='RECYCLE' AND v_ship_id<>'recycler' THEN raise exception 'RECYCLE mixed fleet may contain only recyclers'; END IF;$$;

    select p.oid, p.prosrc::text into v_oid, v_body
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_fleet_mixed'
       and pg_get_function_identity_arguments(p.oid)
         = 'p_player_id uuid, p_origin_planet_id uuid, p_destination_planet_id uuid, p_ships jsonb, p_mission_type text';
    if v_oid is null then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: start_fleet_mixed not found with the expected signature';
    end if;

    v_occurrences := (length(v_body) - length(replace(v_body, v_anchor, ''))) / length(v_anchor);
    if v_occurrences <> 1 then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: start_fleet_mixed anchor found % times (expected 1)', v_occurrences;
    end if;

    v_body := replace(v_body, v_anchor, v_anchor || chr(10) ||
        '   IF v_mission_type=''ESPIONAGE'' AND v_ship_id<>''espionage_probe'' THEN raise exception ''ESPIONAGE_MISSION_REQUIRES_PROBES: only espionage_probe may be sent on an ESPIONAGE mission (got %)'', v_ship_id; END IF;');

    execute format($fmt$
        create or replace function public.start_fleet_mixed(
            p_player_id uuid,
            p_origin_planet_id uuid,
            p_destination_planet_id uuid,
            p_ships jsonb,
            p_mission_type text default 'TRANSPORT'::text
        ) returns table(
            fleet_id uuid,
            ship_id text,
            quantity bigint,
            origin_planet_id uuid,
            destination_planet_id uuid,
            mission_type text,
            started_at timestamptz,
            arrives_at timestamptz
        )
        language plpgsql
        security definer
        set search_path to 'public', 'pg_temp'
        as $fn$ %s $fn$
    $fmt$, v_body);
end;
$patch$;

/* ---------------- start_fleet: the single-ship dispatcher gets the same rule ------------- */
do $patch$
declare
    v_oid oid;
    v_body text;
    v_anchor text;
    v_occurrences integer;
begin
    v_anchor := $$raise exception 'Invalid mission type: %',v_mission_type; END IF;$$;

    select p.oid, p.prosrc::text into v_oid, v_body
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_fleet'
       and pg_get_function_identity_arguments(p.oid)
         = 'p_player_id uuid, p_origin_planet_id uuid, p_destination_planet_id uuid, p_ship_id text, p_quantity bigint, p_mission_type text';
    if v_oid is null then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: start_fleet not found with the expected signature';
    end if;

    v_occurrences := (length(v_body) - length(replace(v_body, v_anchor, ''))) / length(v_anchor);
    if v_occurrences <> 1 then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: start_fleet anchor found % times (expected 1)', v_occurrences;
    end if;

    v_body := replace(v_body, v_anchor, v_anchor || chr(10) ||
        ' /* the composition rule: an ESPIONAGE mission is flown by probes, never by combat or civil hulls */' || chr(10) ||
        ' if v_mission_type=''ESPIONAGE'' and p_ship_id<>''espionage_probe'' then raise exception ''ESPIONAGE_MISSION_REQUIRES_PROBES: only espionage_probe may be sent on an ESPIONAGE mission (got %)'', p_ship_id; end if;');

    execute format($fmt$
        create or replace function public.start_fleet(
            p_player_id uuid,
            p_origin_planet_id uuid,
            p_destination_planet_id uuid,
            p_ship_id text,
            p_quantity bigint,
            p_mission_type text default 'TRANSPORT'::text
        ) returns table(
            fleet_id uuid,
            ship_id text,
            quantity bigint,
            origin_planet_id uuid,
            destination_planet_id uuid,
            mission_type text,
            started_at timestamptz,
            arrives_at timestamptz
        )
        language plpgsql
        security definer
        set search_path to 'public', 'pg_temp'
        as $fn$ %s $fn$
    $fmt$, v_body);
end;
$patch$;

-- The ACL is NOT touched by the patch (create or replace keeps the existing privileges), but the two
-- dispatchers are re-asserted here so the migration fails loudly if a future edit ever opened them.
grant execute on function public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.start_fleet_mixed(uuid,uuid,uuid,jsonb,text) to service_role;
grant execute on function public.start_fleet(uuid,uuid,uuid,text,bigint,text) to authenticated;
grant execute on function public.start_fleet(uuid,uuid,uuid,text,bigint,text) to service_role;

-- Post-conditions: the rule is present in both dispatchers, both stayed SECURITY DEFINER with the
-- pinned search_path, and the RECYCLE rule it mirrors is still there untouched.
do $verify$
declare
    v_mixed text;
    v_single text;
    v_bad text;
begin
    select p.prosrc::text into v_mixed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_fleet_mixed';
    select p.prosrc::text into v_single
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'start_fleet';

    if v_mixed not ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%' then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: the mixed dispatcher lost the espionage composition rule';
    end if;
    if v_single not ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%' then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: the single dispatcher lost the espionage composition rule';
    end if;

    -- the rule the new guard mirrors must not have been damaged
    if v_mixed not ilike '%RECYCLE mixed fleet may contain only recyclers%' then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: the RECYCLE rule was damaged';
    end if;

    -- both must still be SECURITY DEFINER with the pinned search_path
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname in ('start_fleet','start_fleet_mixed') and p.prosecdef) then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: a dispatcher lost SECURITY DEFINER';
    end if;
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname in ('start_fleet','start_fleet_mixed')
                  and (p.proconfig is null or p.proconfig::text not ilike '%search_path=public, pg_temp%')) then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: a dispatcher lost its pinned search_path';
    end if;

    -- the resolver must NOT have been touched by this migration
    select string_agg(a, ' ') into v_bad
      from unnest(regexp_split_to_array(
             (select p.prosrc::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'resolve_espionage_arrival'), '\s+')) a
     where a ilike '%ESPIONAGE_MISSION_REQUIRES_PROBES%';
    if v_bad is not null then
        raise exception 'ESPIONAGE_COMPOSITION_RULE: the resolver must not carry the dispatch guard (%s)', v_bad;
    end if;
end;
$verify$;

        )
        language plpgsql
        security definer
        set search_path to 'public', 'pg_temp'
        as $fn$ %s $fn$
    $fmt$, v_body);
end;
$patch$;

        set search_path to 'public', 'pg_temp'
        as $fn$ %s $fn$
    $fmt$, v_body);
end;
$patch$;

