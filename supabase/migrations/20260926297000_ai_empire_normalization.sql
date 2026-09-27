-- ============================================================================
-- AI EMPIRE NORMALIZATION (backfill) — LGI (2026-09-26)
-- ----------------------------------------------------------------------------
-- The 586 AI empires created BEFORE 20260926296000 were born with the legacy initial state
-- (`planet_resources` 0/0/0/0 and no `player_research` rows): the old seeder wrote literal zeros and never
-- called `initialize_player_research`. 20260926296000 fixed the BIRTH path; this migration normalises the
-- EXISTING empires so they carry exactly the state a new human player receives.
--
-- What is normalised (and only this):
--   * `planet_resources` of the AI homeworld, ONLY while it is still the untouched legacy zero state;
--   * `player_research`: the 16 level-0 rows, through the shared authority `bootstrap_new_player_state`;
--   * `ai_player_profiles`: created when missing, so the persistent DORMANT state exists.
--
-- Safety properties (all asserted by supabase/tests/ai_normalization_and_beginner_protection.sql):
--   * idempotent: a second run reports 0 candidates and changes nothing;
--   * never overwrites progress: an empire with any research row, building, ship, defence, queue row, fleet
--     mission or non-legacy resource value is skipped and counted as `skipped_with_progress`;
--   * never activates: the status column is never written, so every AI stays DORMANT;
--   * identity preserved: no player is deleted/recreated and no planet, position, personality or relationship
--     is changed;
--   * no inventory is created: buildings, ships and defences stay empty;
--   * no literals: the endowment is applied with `SET metal = DEFAULT, …`, so the single source of the initial
--     quantities remains the `planet_resources` schema defaults (500/500/0/0) — exactly what a human gets;
--   * `p_dry_run` reports candidates without writing (the step 1-3 protocol before a mass LIVE operation) and
--     `p_limit` allows a verified sample first.
--
-- It does NOT rely on `reconcile_universe_ai_population`: that function only creates NEW empires to reach a
-- population density and would never touch an existing row.
-- ============================================================================

create or replace function public.normalize_existing_ai_empires(p_universe_id uuid default null,
                                                                p_limit integer default null,
                                                                p_dry_run boolean default false)
returns table(out_candidates integer, out_normalized integer, out_already_ok integer,
              out_skipped_with_progress integer)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_rec record;
    v_candidates integer := 0;
    v_normalized integer := 0;
begin
    for v_rec in
        select pl.id as ai_player_id, h.id as homeworld_id
          from public.players pl
          join public.planets h
            on h.player_id = pl.id
           and h.is_homeworld
           and not h.is_destroyed
           and h.kind = 'PLANET'
          join public.planet_resources pr on pr.planet_id = h.id
         where pl.player_type = 'AI'
           and pl.user_id is null
           and (p_universe_id is null or pl.universe_id = p_universe_id)
           /* legacy zero state only */
           and coalesce(pr.metal, 0) = 0
           and coalesce(pr.crystal, 0) = 0
           and coalesce(pr.deuterium, 0) = 0
           and coalesce(pr.energy, 0) = 0
           /* no progress of any kind */
           and not exists (select 1 from public.player_research r where r.player_id = pl.id)
           and not exists (select 1 from public.planet_buildings b where b.planet_id = h.id)
           and not exists (select 1 from public.planet_ships s where s.planet_id = h.id)
           and not exists (select 1 from public.planet_defenses d where d.planet_id = h.id)
           and not exists (select 1 from public.building_queue q where q.planet_id = h.id)
           and not exists (select 1 from public.research_queue q where q.planet_id = h.id)
           and not exists (select 1 from public.fleet_movements m where m.player_id = pl.id)
         order by pl.created_at, pl.id
         limit coalesce(p_limit, 2147483647)
    loop
        v_candidates := v_candidates + 1;

        if not coalesce(p_dry_run, false) then
            /* the endowment: the schema defaults, never a literal, and never over existing progress */
            update public.planet_resources pr
               set metal = default, crystal = default, deuterium = default, energy = default
             where pr.planet_id = v_rec.homeworld_id
               and pr.metal = 0 and pr.crystal = 0 and pr.deuterium = 0 and pr.energy = 0;

            /* the shared bootstrap authority: initial research (+ idempotent resource guarantee) */
            perform public.bootstrap_new_player_state(v_rec.ai_player_id, v_rec.homeworld_id);

            /* persistent DORMANT profile (inserted only when missing; the status is never written here) */
            perform public.ai_ensure_player_profile(v_rec.ai_player_id);

            v_normalized := v_normalized + 1;
        end if;
    end loop;

    select count(*) into out_already_ok
      from public.players pl
      join public.planets h on h.player_id = pl.id and h.is_homeworld and not h.is_destroyed and h.kind = 'PLANET'
      join public.planet_resources pr on pr.planet_id = h.id
     where pl.player_type = 'AI' and pl.user_id is null
       and (p_universe_id is null or pl.universe_id = p_universe_id)
       and pr.metal = 500 and pr.crystal = 500 and pr.deuterium = 0
       and (select count(*) from public.player_research r where r.player_id = pl.id) = 16;

    select count(*) into out_skipped_with_progress
      from public.players pl
      join public.planets h on h.player_id = pl.id and h.is_homeworld and not h.is_destroyed and h.kind = 'PLANET'
      join public.planet_resources pr on pr.planet_id = h.id
     where pl.player_type = 'AI' and pl.user_id is null
       and (p_universe_id is null or pl.universe_id = p_universe_id)
       and not (pr.metal = 500 and pr.crystal = 500 and pr.deuterium = 0
                and (select count(*) from public.player_research r where r.player_id = pl.id) = 16)
       and (coalesce(pr.metal, 0) <> 0 or coalesce(pr.crystal, 0) <> 0
            or coalesce(pr.deuterium, 0) <> 0 or coalesce(pr.energy, 0) <> 0
            or exists (select 1 from public.player_research r where r.player_id = pl.id)
            or exists (select 1 from public.planet_buildings b where b.planet_id = h.id)
            or exists (select 1 from public.planet_ships s where s.planet_id = h.id)
            or exists (select 1 from public.planet_defenses d where d.planet_id = h.id)
            or exists (select 1 from public.fleet_movements m where m.player_id = pl.id));

    out_candidates := v_candidates;
    out_normalized := v_normalized;
    return next;
end;
$function$;

revoke all on function public.normalize_existing_ai_empires(uuid, integer, boolean) from public, anon, authenticated;
grant execute on function public.normalize_existing_ai_empires(uuid, integer, boolean) to service_role;