-- ============================================================================
-- SHARED PLAYER BOOTSTRAP — LGI (2026-09-26)
-- ----------------------------------------------------------------------------
-- Problem: a new HUMAN player and a new AI player were born with DIFFERENT initial state.
--
--   provision_player (LIVE, the human bootstrap)        reconcile_universe_ai_population (the AI seeder)
--   --------------------------------------------------  --------------------------------------------------
--   players:        user_id = auth.uid(), last_activity  players:   user_id NULL, username AI-Gx-Sy-Pz,
--                   (points 0, rank NULL, dark_matter 0,            points 0, rank NULL, dark_matter 0,
--                    is_guest false, player_type HUMAN)              is_guest false, player_type AI
--   planets:        fields_total 163, fields_used 0,     planets:   same fields, name 'AI World …'
--                   is_homeworld true, temperatures NULL
--   planet_resources: 500 / 500 / 0 / 0                  planet_resources: 0 / 0 / 0 / 0   <-- DIVERGENCE
--   initialize_player_research -> 16 x level 0           (missing)                         <-- DIVERGENCE
--   buildings / ships / defences: none                    none                              (already equal)
--
-- Rule (owner): an AI receives EXACTLY the same initial values as a new human. No AI bonus, no AI penalty, no
-- special AI quantities, no second initial-economy system.
--
-- Solution (option B of the brief): ONE shared authority used by BOTH paths.
--   * the initial endowment is NOT re-declared anywhere: it lives in the schema defaults of planet_resources
--     (metal 500, crystal 500, deuterium 0, energy 0, timestamps now()), which is why the helper inserts ONLY
--     the planet id — there is no number to copy and no second source of truth;
--   * initial research comes from the existing `initialize_player_research(player)` (idempotent insert of a
--     level-0 row per research definition, 16 rows today);
--   * `provision_player` now DELEGATES its initial-state block to the helper (same behaviour, one authority);
--   * the AI seeder now DELEGATES to the same helper instead of writing zeros, and additionally creates the
--     player's DORMANT profile (`ai_ensure_player_profile`) so the persistent state exists from birth.
--
-- Nothing else changes: both functions keep their signatures, SECURITY DEFINER + search_path, returned
-- columns, ACLs, and every other statement byte-for-byte.
-- ============================================================================

create or replace function public.bootstrap_new_player_state(p_player_id uuid, p_planet_id uuid)
returns table(out_metal numeric, out_crystal numeric, out_deuterium numeric, out_energy numeric,
              out_research_rows integer)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_research_rows integer;
begin
    if p_player_id is null or p_planet_id is null then
        raise exception 'BOOTSTRAP_ARGUMENT_REQUIRED';
    end if;

    if not exists (select 1 from public.planets p
                    where p.id = p_planet_id and p.player_id = p_player_id) then
        raise exception 'BOOTSTRAP_PLANET_NOT_OWNED: % / %', p_player_id, p_planet_id;
    end if;

    /* THE initial endowment: the planet_resources column defaults (500 / 500 / 0 / 0). No literals on purpose,
       so a human and an AI cannot drift apart. Idempotent: a second call adds nothing. */
    insert into public.planet_resources (planet_id)
    values (p_planet_id)
    on conflict (planet_id) do nothing;

    /* initial research: the existing, reusable, idempotent authority (16 x level 0 today) */
    v_research_rows := public.initialize_player_research(p_player_id);

    select pr.metal, pr.crystal, pr.deuterium, pr.energy
      into out_metal, out_crystal, out_deuterium, out_energy
      from public.planet_resources pr
     where pr.planet_id = p_planet_id;

    out_research_rows := v_research_rows;
    return next;
end;
$function$;

revoke all on function public.bootstrap_new_player_state(uuid, uuid) from public, anon, authenticated;
grant execute on function public.bootstrap_new_player_state(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 1. Human bootstrap — identical behaviour, initial state delegated to the shared authority
-- ---------------------------------------------------------------------------
create or replace function public.provision_player(
  p_username text,
  p_country_code text default 'XX'
)
returns table(
  player_id uuid,
  planet_id uuid,
  username text,
  galaxy integer,
  system integer,
  planet_position integer
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_username text := btrim(p_username);
  v_country text := upper(coalesce(nullif(btrim(p_country_code), ''), 'XX'));
  v_player_id uuid;
  v_planet_id uuid;
  v_universe_id uuid;
  v_galaxy integer;
  v_system integer;
  v_planet_position integer;
begin
  if v_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED';
  end if;

  if length(v_username) < 3 or length(v_username) > 24 then
    raise exception 'USERNAME_LENGTH_INVALID';
  end if;

  if v_username !~ '^[[:alnum:] _.-]+$' then
    raise exception 'USERNAME_CHARACTERS_INVALID';
  end if;

  if lower(v_username) = 'devplayer' then
    raise exception 'USERNAME_RESERVED';
  end if;

  select pl.id into v_player_id
  from public.players pl
  where pl.user_id = v_user_id
  limit 1;

  if v_player_id is not null then
    select p.id, p.galaxy, p.system, p.position
      into v_planet_id, v_galaxy, v_system, v_planet_position
    from public.planets p
    where p.player_id = v_player_id
      and p.is_homeworld = true
      and p.is_destroyed = false
    order by p.created_at
    limit 1;

    return query
      select v_player_id, v_planet_id,
             (select pl.username from public.players pl where pl.id = v_player_id),
             v_galaxy, v_system, v_planet_position;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('lgi_player_provisioning_v1', 0));

  select u.id into v_universe_id
  from public.universes u
  where u.is_active = true
  order by u.created_at desc
  limit 1;

  if v_universe_id is null then
    raise exception 'ACTIVE_UNIVERSE_NOT_FOUND';
  end if;

  if exists (
    select 1 from public.players pl
    where pl.universe_id = v_universe_id
      and pl.player_type = 'HUMAN'
      and lower(pl.username) = lower(v_username)
  ) then
    raise exception 'USERNAME_ALREADY_TAKEN';
  end if;

  select slot.galaxy, slot.system, slot.planet_position
    into v_galaxy, v_system, v_planet_position
  from (
    select ug.galaxy, s.system, pos.planet_position
    from public.universe_galaxies ug
    cross join lateral generate_series(1, ug.system_count) as s(system)
    cross join lateral generate_series(1, 15) as pos(planet_position)
    where ug.universe_id = v_universe_id
    order by ug.galaxy, s.system, pos.planet_position
  ) slot
  left join public.planets existing
    on existing.universe_id = v_universe_id
   and existing.galaxy = slot.galaxy
   and existing.system = slot.system
   and existing.position = slot.planet_position
           and existing.kind = 'PLANET'
   and existing.is_destroyed = false
  where existing.id is null
  limit 1;

  if v_galaxy is null then
    raise exception 'UNIVERSE_FULL';
  end if;

  insert into public.players (user_id, universe_id, username, last_activity_at)
  values (v_user_id, v_universe_id, v_username, now())
  returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, galaxy, system, position,
    fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_galaxy, v_system, v_planet_position,
    163, 0, true, false
  ) returning id into v_planet_id;

  /* initial state: the ONE shared authority (initial endowment + initial research) */
  perform public.bootstrap_new_player_state(v_player_id, v_planet_id);

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position;
end;
$function$;

revoke execute on function public.provision_player(text, text) from public;
revoke execute on function public.provision_player(text, text) from anon;
grant execute on function public.provision_player(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. AI bootstrap — the AI player is born with the HUMAN initial state, DORMANT
-- ---------------------------------------------------------------------------
create or replace function public.reconcile_universe_ai_population(p_universe_id uuid)
returns table(positions_unlocked bigint, ai_before bigint, ai_after bigint, target_ai bigint,
              planets_created integer)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
DECLARE
    v_state public.universe_population_state%ROWTYPE;
    v_positions bigint;
    v_systems bigint;
    v_ai_before bigint;
    v_ai_after bigint;
    v_target bigint;
    v_needed bigint;
    v_to_create integer;
    v_created integer := 0;
    v_candidate record;
    v_player_id uuid;
    v_planet_id uuid;
    v_now timestamptz := now();
    v_lower_density numeric;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.universes WHERE id = p_universe_id
    ) THEN
        RAISE EXCEPTION 'Universe % does not exist', p_universe_id;
    END IF;

    INSERT INTO public.universe_population_state (universe_id, next_reconciliation_at)
    VALUES (p_universe_id, v_now)
    ON CONFLICT (universe_id) DO NOTHING;

    SELECT *
    INTO v_state
    FROM public.universe_population_state
    WHERE universe_id = p_universe_id
    FOR UPDATE;

    SELECT COALESCE(SUM(system_count), 0)::bigint
    INTO v_systems
    FROM public.universe_galaxies
    WHERE universe_id = p_universe_id;

    v_positions := v_systems * 15;

    SELECT COUNT(*)::bigint
    INTO v_ai_before
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.universe_id = p_universe_id
      AND pl.player_type = 'AI'
      AND p.is_destroyed = false;

    /*
     * ai_density_target is the desired centre of the band.
     * ai_density_tolerance defines the acceptable lower/upper band.
     * We only create AI planets when density falls below the lower edge.
     * We deliberately do not delete AI planets when density exceeds the
     * upper edge: existing AI empires must not be destroyed by maintenance.
     */
    v_lower_density := GREATEST(
        v_state.ai_density_target - v_state.ai_density_tolerance,
        0
    );

    v_target := CEIL(v_positions * v_lower_density)::bigint;
    v_needed := GREATEST(v_target - v_ai_before, 0);
    v_to_create := LEAST(v_needed, GREATEST(v_state.ai_generation_batch, 0));

    IF v_to_create > 0 THEN
        FOR v_candidate IN
            SELECT g.galaxy, s.system_no, pos.position
            FROM public.universe_galaxies g
            CROSS JOIN LATERAL generate_series(1, g.system_count) AS s(system_no)
            CROSS JOIN LATERAL generate_series(1, 15) AS pos(position)
            WHERE g.universe_id = p_universe_id
              AND NOT EXISTS (
                  SELECT 1
                  FROM public.planets existing
                  WHERE existing.universe_id = p_universe_id
                    AND existing.galaxy = g.galaxy
                    AND existing.system = s.system_no
                    AND existing.position = pos.position
             AND existing.kind = 'PLANET'
              )
            ORDER BY g.galaxy, s.system_no, pos.position
            LIMIT v_to_create
        LOOP
            BEGIN
                INSERT INTO public.players (
                    universe_id,
                    user_id,
                    username,
                    points,
                    rank,
                    dark_matter,
                    is_guest,
                    player_type
                )
                VALUES (
                    p_universe_id,
                    NULL,
                    format('AI-G%s-S%s-P%s', v_candidate.galaxy, v_candidate.system_no, v_candidate.position),
                    0,
                    NULL,
                    0,
                    false,
                    'AI'
                )
                RETURNING id INTO v_player_id;

                INSERT INTO public.planets (
                    universe_id,
                    player_id,
                    name,
                    galaxy,
                    system,
                    position,
                    temperature_min,
                    temperature_max,
                    fields_total,
                    fields_used,
                    is_homeworld,
                    is_destroyed
                )
                VALUES (
                    p_universe_id,
                    v_player_id,
                    format('AI World G%s:S%s:P%s', v_candidate.galaxy, v_candidate.system_no, v_candidate.position),
                    v_candidate.galaxy,
                    v_candidate.system_no,
                    v_candidate.position,
                    NULL,
                    NULL,
                    163,
                    0,
                    true,
                    false
                )
                RETURNING id INTO v_planet_id;

                /* Initial state: EXACTLY the human bootstrap, through the ONE shared authority
                   (initial endowment from the planet_resources defaults + initial research). The seeder no
                   longer writes literal zeros, so an AI empire cannot be born poorer than a human one. */
                PERFORM public.bootstrap_new_player_state(v_player_id, v_planet_id);

                /* Persistent DORMANT state from birth: the profile row exists immediately with
                   status = 'DORMANT' (column default) and a stable personality. */
                PERFORM public.ai_ensure_player_profile(v_player_id);

                v_created := v_created + 1;
            EXCEPTION WHEN unique_violation THEN
                NULL;
            END;

            EXIT WHEN v_created >= v_to_create;
        END LOOP;
    END IF;

    SELECT COUNT(*)::bigint
    INTO v_ai_after
    FROM public.planets p
    JOIN public.players pl ON pl.id = p.player_id
    WHERE p.universe_id = p_universe_id
      AND pl.player_type = 'AI'
      AND p.is_destroyed = false;

    UPDATE public.universe_population_state
    SET unlocked_systems = v_systems,
        unlocked_positions = v_positions,
        ai_planets_count = v_ai_after,
        next_reconciliation_at = v_now + make_interval(secs => GREATEST(v_state.reconciliation_interval_seconds, 1)),
        updated_at = v_now
    WHERE universe_id = p_universe_id;

    RETURN QUERY
    SELECT v_positions, v_ai_before, v_ai_after, v_target, v_created;
END;
$function$;

revoke all on function public.reconcile_universe_ai_population(uuid) from public, anon, authenticated;
grant execute on function public.reconcile_universe_ai_population(uuid) to service_role;