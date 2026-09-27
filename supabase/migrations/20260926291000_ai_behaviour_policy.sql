-- ============================================================================
-- AI BEHAVIOUR POLICY — LGI (owner-approved, 2026-09-26)
-- ----------------------------------------------------------------------------
-- Replaces the first-cut policy (one action per tick: energy -> economy -> research -> colony) with the
-- full gameplay policy: personality weights, planet specialisation, deterministic daily activity windows
-- with real inactivity, cooldowns, espionage-driven targeting, probabilistic attacks with a 24 h
-- protection for young AIs, colonisation, and fleet/defence production.
--
--   The AI decides WHAT to do; the certified contracts execute it and stay authoritative:
--     can_start_building/start_building · can_start_research/start_research · can_build_ship/start_ship ·
--     can_build_defense/start_defense · start_fleet_mixed (ESPIONAGE/ATTACK) · start_colonize_fleet ·
--     assert_player_fleet_slot_available (fleet-slot authority) · check_colony_cap (colony-cap authority)
--     · ai_actor_begin/ai_actor_end (the declared service actor).
--
--   No parallel rule engine: no cost, production, requirement, speed or fuel formula is duplicated here.
--   Every legality question is asked to the contract that owns it; the policy only ranks legal actions.
--
--   OGameX reference: none for a player-AI policy (NPCFleetGeneratorService builds enemy expedition
--   fleets). Espionage reveal thresholds and the colonisation validity list were read from OGameX and are
--   respected by the certified contracts, not reimplemented. `random()` is never used: every roll is
--   deterministic (ai_roll) so a replayed tick reproduces the same decision.
-- ============================================================================

drop function if exists public.ai_decide_and_act(uuid, numeric);

create or replace function public.ai_decide_and_act(p_player_id uuid,
                                                    p_budget_percent numeric default 60,
                                                    p_at timestamptz default null)
returns table(action text, target text, result text)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_at timestamptz := coalesce(p_at, now());
    v_profile record;
    v_personality text;
    v_weights record;
    v_created timestamptz;
    v_protected boolean;
    v_planets uuid[];
    v_planet uuid;
    v_planet_profile record;
    v_res record;
    v_prod record;
    v_can record;
    v_cap record;
    v_building text;
    v_unit text;
    v_unit_type text;
    v_after record;
    v_candidate record;
    v_best_family text := null;
    v_best_score numeric := 0;
    v_best_target text := null;
    v_best_cooldown text := null;
    v_attack_seen boolean := false;
    v_score numeric;
    v_need numeric;
    v_roll numeric;
    v_slot_free boolean;
    v_ships jsonb := '{}'::jsonb;
    v_probes bigint := 0;
    v_warships bigint := 0;
    v_defense_count bigint := 0;
    v_colony_ships bigint := 0;
    v_free boolean := false;
    v_g integer; v_s integer; v_p integer;
    v_i integer;
    v_research text;
    v_target_planet uuid;
    v_relative numeric;
    v_prob numeric;
begin
    if p_budget_percent is null or p_budget_percent <= 0 or p_budget_percent > 100 then
        raise exception 'AI_BUDGET_INVALID: %', p_budget_percent;
    end if;

    /* ---------- gates: AI profile, daily activity window, cooldown ---------- */
    select * into v_profile from public.ai_ensure_player_profile(p_player_id);
    v_personality := v_profile.personality;
    select * into v_weights from public.ai_personality_weights(v_personality);

    if not public.ai_is_active_at(p_player_id, v_at) then
        action := 'none'; target := null; result := 'AI_INACTIVE_WINDOW';
        return next; return;
    end if;

    if v_profile.next_action_at is not null and v_at < v_profile.next_action_at then
        action := 'none'; target := null;
        result := 'AI_COOLDOWN_UNTIL_' || to_char(v_profile.next_action_at at time zone 'utc', 'YYYY-MM-DD HH24:MI');
        return next; return;
    end if;

    /* ---------- focus body: rotates deterministically by UTC hour across the AI's planets ---------- */
    select array_agg(p.id order by p.is_homeworld desc, p.created_at, p.id) into v_planets
      from public.planets p
     where p.player_id = p_player_id and not p.is_destroyed;

    if v_planets is null then
        action := 'none'; target := null; result := 'AI_NO_PLANET';
        return next; return;
    end if;

    v_planet := v_planets[1 + (extract(hour from (v_at at time zone 'utc'))::integer
                               % array_length(v_planets, 1))];

    select * into v_planet_profile from public.ai_planet_profile(v_planet);
    select * into v_res from public.planet_resources pr where pr.planet_id = v_planet;
    select * into v_prod from public.calculate_planet_production(v_planet);

    select pl.created_at into v_created from public.players pl where pl.id = p_player_id;
    v_protected := v_at < v_created + interval '24 hours';

    /* ---------- fleet slot + war material, all from certified sources ---------- */
    v_slot_free := true;
    begin
        perform public.assert_player_fleet_slot_available(p_player_id);
    exception when others then
        v_slot_free := false;
    end;

    select coalesce(sum(ps.quantity) filter (where ps.ship_id = 'espionage_probe'), 0),
           coalesce(sum(ps.quantity) filter (where ps.ship_id = 'colony_ship'), 0)
      into v_probes, v_colony_ships
      from public.planet_ships ps
     where ps.planet_id = v_planet;

    select coalesce(sum(ps.quantity), 0) into v_warships
      from public.planet_ships ps
      join public.ship_definitions sd on sd.id = ps.ship_id
     where ps.planet_id = v_planet and sd.ship_type = 'combat';

    select coalesce(sum(pd.quantity), 0) into v_defense_count
      from public.planet_defenses pd
     where pd.planet_id = v_planet;

    /* ---------- family 1: building ---------- */
    if coalesce(v_prod.energy_per_hour, 0) <= 0 then
        v_building := 'solar_plant';
    elsif v_planet_profile.template = 'RESEARCH_WORLD'
          and coalesce((select pb.level from public.planet_buildings pb
                         where pb.planet_id = v_planet and pb.building_id = 'research_lab'), 0) = 0 then
        v_building := 'research_lab';
    elsif v_planet_profile.template in ('MILITARY_WORLD', 'FLEET_BASE')
          and coalesce((select pb.level from public.planet_buildings pb
                         where pb.planet_id = v_planet and pb.building_id = 'shipyard'), 0) < 4 then
        v_building := 'shipyard';
    else
        select b.id into v_building
          from unnest(array['metal_mine', 'crystal_mine', 'deuterium_synthesizer']) as b(id)
          left join public.planet_buildings pb on pb.planet_id = v_planet and pb.building_id = b.id
         order by coalesce(pb.level, 0), b.id
         limit 1;
    end if;

    select * into v_can from public.can_start_building(p_player_id, v_planet, v_building) limit 1;
    v_need := case when coalesce(v_prod.energy_per_hour, 0) <= 0 then 1.00
                   else 0.55 + 0.15 * (1 - coalesce(v_planet_profile.variation, 0)) end;
    v_score := public.ai_score(
        v_weights.economy,
        coalesce(v_can.allowed, false)
        and coalesce(v_can.cost_metal, 0) <= coalesce(v_res.metal, 0) * p_budget_percent / 100
        and coalesce(v_can.cost_crystal, 0) <= coalesce(v_res.crystal, 0) * p_budget_percent / 100
        and coalesce(v_can.cost_deuterium, 0) <= greatest(0, coalesce(v_res.deuterium, 0) - 1000) * p_budget_percent / 100,
        v_need, public.ai_roll(p_player_id, 'building', v_at));

    if v_score > v_best_score then
        v_best_score := v_score; v_best_family := 'building';
        v_best_target := v_building; v_best_cooldown := 'building';
    end if;

    /* ---------- family 2: research (doctrine order, first allowed and affordable wins) ---------- */
    foreach v_research in array array[
        'energy_technology', 'combustion_drive', 'espionage_technology', 'computer_technology', 'astrophysics',
        'laser_technology', 'armour_technology', 'shielding_technology', 'weapons_technology', 'ion_technology',
        'hyperspace_technology', 'impulse_drive', 'plasma_technology', 'hyperspace_drive',
        'intergalactic_research_network', 'graviton_technology'
    ] loop
        select * into v_can from public.can_start_research(p_player_id, v_planet, v_research) limit 1;
        if coalesce(v_can.allowed, false)
           and coalesce(v_can.cost_metal, 0) <= coalesce(v_res.metal, 0) * p_budget_percent / 100
           and coalesce(v_can.cost_crystal, 0) <= coalesce(v_res.crystal, 0) * p_budget_percent / 100
           and coalesce(v_can.cost_deuterium, 0) <= greatest(0, coalesce(v_res.deuterium, 0) - 1000) * p_budget_percent / 100
        then
            v_need := case when v_planet_profile.template = 'RESEARCH_WORLD' then 0.70 else 0.55 end;
            v_score := public.ai_score(v_weights.research, true, v_need,
                                       public.ai_roll(p_player_id, 'research', v_at));
            if v_score > v_best_score then
                v_best_score := v_score; v_best_family := 'research';
                v_best_target := v_research; v_best_cooldown := 'research';
            end if;
            exit;
        end if;
    end loop;

    /* ---------- family 3: shipyard (doctrine composition, certified availability + budget) ---------- */
    v_unit := public.ai_pick_unit(p_player_id, v_planet, 'SHIP', v_personality, v_planet_profile.template,
                                  p_budget_percent, public.ai_roll(p_player_id, 'shipyard', v_at));
    if v_unit is not null then
        select sd.ship_type into v_unit_type from public.ship_definitions sd where sd.id = v_unit;
        v_need := 0.45
                  + case when v_planet_profile.template in ('MILITARY_WORLD', 'FLEET_BASE') then 0.20 else 0 end
                  + 0.10 * coalesce(v_planet_profile.variation, 0);
        v_score := public.ai_score(
            case when v_unit_type = 'combat' then v_weights.military else v_weights.economy end,
            true, v_need, public.ai_roll(p_player_id, 'shipyard_score', v_at));
        if v_score > v_best_score then
            v_best_score := v_score; v_best_family := 'shipyard';
            v_best_target := v_unit; v_best_cooldown := 'production';
        end if;
    end if;

    /* ---------- family 4: defence (higher need on a defenceless world) ---------- */
    v_unit := public.ai_pick_unit(p_player_id, v_planet, 'DEFENSE', v_personality, v_planet_profile.template,
                                  p_budget_percent, public.ai_roll(p_player_id, 'defense', v_at));
    if v_unit is not null then
        v_need := 0.35
                  + case when coalesce(v_defense_count, 0) = 0 then 0.25 else 0 end
                  + case when v_planet_profile.template = 'MILITARY_WORLD' then 0.10 else 0 end;
        v_score := public.ai_score(v_weights.military, true, v_need,
                                   public.ai_roll(p_player_id, 'defense_score', v_at));
        if v_score > v_best_score then
            v_best_score := v_score; v_best_family := 'defense';
            v_best_target := v_unit; v_best_cooldown := 'production';
        end if;
    end if;

    /* ---------- family 5: espionage (probes + free fleet slot + a candidate worth knowing) ---------- */
    if coalesce(v_probes, 0) > 0 and v_slot_free then
        select * into v_candidate from public.ai_espionage_candidates(p_player_id, v_planet, 3) limit 1;
        if v_candidate.target_planet_id is not null then
            select * into v_after from public.ai_known_target_power(p_player_id, v_candidate.target_planet_id);
            v_need := case when coalesce(v_after.known, false) then 0.55 else 0.80 end;
            v_score := public.ai_score(v_weights.espionage, true, v_need,
                                       public.ai_roll(p_player_id, 'espionage_score', v_at));
            if v_score > v_best_score then
                v_best_score := v_score; v_best_family := 'espionage';
                v_best_target := v_candidate.target_planet_id::text; v_best_cooldown := 'espionage';
            end if;
        end if;
    end if;

    /* ---------- family 6: attack (espionage information, relative power, probability, protection) ---------- */
    if coalesce(v_warships, 0) > 0 and v_slot_free then
        for v_candidate in select * from public.ai_attack_candidates(p_player_id, v_planet, p_budget_percent, 3) loop
            if coalesce(v_candidate.relative_power, 0) < 0.75 then
                continue;
            end if;
            v_attack_seen := true;
            if v_protected then
                continue;   /* first 24 h of the AI: P(attack) = 0, no exception */
            end if;
            v_prob := public.ai_attack_probability(v_candidate.relative_power, v_personality);
            if public.ai_roll(p_player_id, 'attack_roll|' || v_candidate.target_planet_id::text, v_at) >= v_prob then
                continue;   /* legal but not chosen this time: attacks are probabilistic, not automatic */
            end if;
            v_need := least(1.50, greatest(0.25, v_candidate.relative_power));
            v_score := public.ai_score(v_weights.military, true, v_need,
                                       public.ai_roll(p_player_id, 'attack_score', v_at));
            if v_score > v_best_score then
                v_best_score := v_score; v_best_family := 'attack';
                v_best_target := v_candidate.target_planet_id::text; v_best_cooldown := 'attack';
            end if;
            exit;
        end loop;
    end if;

    /* ---------- family 7: colonisation (deliberately low probability) ---------- */
    if coalesce(v_colony_ships, 0) > 0 and v_slot_free then
        select * into v_cap from public.check_colony_cap(p_player_id) limit 1;
        if coalesce(v_cap.allowed, false) then
            v_g := (select p.galaxy from public.planets p where p.id = v_planet);
            for v_i in 1..30 loop
                v_s := 1 + ((v_i - 1) % 10);
                v_p := 5 + ((v_i - 1) / 10);
                v_free := not exists (select 1 from public.planets p
                                       where p.universe_id = (select p2.universe_id from public.planets p2 where p2.id = v_planet)
                                         and p.galaxy = v_g and p.system = v_s
                                         and p.position = v_p and p.kind = 'PLANET' and not p.is_destroyed);
                exit when v_free;
            end loop;

            if v_free then
                v_need := 0.35 + 0.10 * coalesce(v_planet_profile.variation, 0);
                v_score := public.ai_score(v_weights.economy, true, v_need,
                                           public.ai_roll(p_player_id, 'colonization_score', v_at));
                if v_score > v_best_score then
                    v_best_score := v_score; v_best_family := 'colonization';
                    v_best_target := v_g || ':' || v_s || ':' || v_p; v_best_cooldown := 'colonization';
                end if;
            end if;
        end if;
    end if;

    /* ---------- execute the winner: always through the certified dispatchers ---------- */
    if v_best_family is null then
        action := 'none';
        target := null;
        result := case when v_attack_seen and v_protected then 'AI_PROTECTION_24H' else 'AI_IDLE' end;
        return next; return;
    end if;

    if v_best_family = 'building' then
        perform public.start_building(p_player_id, v_planet, v_best_target);
        action := 'building';
    elsif v_best_family = 'research' then
        perform public.start_research(p_player_id, v_planet, v_best_target);
        action := 'research';
    elsif v_best_family = 'shipyard' then
        perform public.start_ship(p_player_id, v_planet, v_best_target, 1);
        action := 'shipyard';
    elsif v_best_family = 'defense' then
        perform public.start_defense(p_player_id, v_planet, v_best_target, 1);
        action := 'defense';
    elsif v_best_family = 'espionage' then
        perform public.start_fleet_mixed(p_player_id, v_planet, v_best_target::uuid,
                                         jsonb_build_object('espionage_probe', least(v_probes, 2)), 'ESPIONAGE');
        action := 'espionage';
    elsif v_best_family = 'attack' then
        /* commit a share of every warship present, never the whole fleet (documented anti-snowball rule) */
        select coalesce(jsonb_object_agg(ps.ship_id,
                        greatest(1, floor(ps.quantity * p_budget_percent / 100))), '{}'::jsonb)
          into v_ships
          from public.planet_ships ps
          join public.ship_definitions sd on sd.id = ps.ship_id
         where ps.planet_id = v_planet and ps.quantity > 0 and sd.ship_type = 'combat';
        perform public.start_fleet_mixed(p_player_id, v_planet, v_best_target::uuid, v_ships, 'ATTACK');
        action := 'attack';
    else
        perform public.start_colonize_fleet(p_player_id, v_planet,
                                            split_part(v_best_target, ':', 1)::integer,
                                            split_part(v_best_target, ':', 2)::integer,
                                            split_part(v_best_target, ':', 3)::integer);
        action := 'colony';
    end if;

    /* ---------- cadence: per-family cooldown weighted by personality + activity stamp ---------- */
    update public.ai_player_profiles app
       set last_action_at = v_at,
           last_action_kind = action,
           next_action_at = v_at + make_interval(mins => public.ai_cooldown_minutes(
                                v_best_cooldown, v_personality,
                                public.ai_roll(p_player_id, 'cooldown|' || action, v_at))),
           updated_at = now()
     where app.player_id = p_player_id;

    update public.players pl set last_activity_at = v_at where pl.id = p_player_id;

    target := v_best_target;
    result := 'STARTED';
    return next;
end;
$function$;

-- ---------------------------------------------------------------------
-- Worker: one decision per AI player per tick, inside the certified service actor contract.
-- A failing player is isolated (sub-transaction) so the batch always completes. The 5-minute cron
-- cadence is unchanged: the daily activity windows (not the job) decide when a decision is allowed.
-- ---------------------------------------------------------------------
drop function if exists public.run_ai_policy_worker(integer, numeric);

create or replace function public.run_ai_policy_worker(p_max_players integer default 25,
                                                       p_budget_percent numeric default 60,
                                                       p_at timestamptz default null)
returns table(out_player_id uuid, out_action text, out_target text, out_result text)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_player record;
    v_decision record;
begin
    if p_max_players is null or p_max_players < 1 then
        raise exception 'AI_WORKER_LIMIT_INVALID: %', p_max_players;
    end if;

    for v_player in
        select pl.id
        from public.players pl
        join public.universes u on u.id = pl.universe_id and u.is_active
        where pl.player_type = 'AI' and pl.user_id is null
          and exists (select 1 from public.planets p
                       where p.player_id = pl.id and p.kind = 'PLANET' and p.is_destroyed = false)
        order by pl.last_activity_at nulls first, pl.created_at
        limit p_max_players
    loop
        out_player_id := v_player.id;
        out_action := 'none';
        out_target := null;
        out_result := 'AI_PENDING';

        perform public.ai_actor_begin(v_player.id);
        begin
            select * into v_decision from public.ai_decide_and_act(v_player.id, p_budget_percent, p_at);
            out_action := coalesce(v_decision.action, 'none');
            out_target := v_decision.target;
            out_result := coalesce(v_decision.result, 'AI_NO_DECISION');
        exception when others then
            out_action := 'none';
            out_target := null;
            out_result := 'AI_ERROR: ' || sqlerrm;
        end;
        perform public.ai_actor_end();

        return next;
    end loop;
end;
$function$;

-- ---------------------------------------------------------------------
-- ACL: the policy stays internal (it runs as the declared service actor).
-- ---------------------------------------------------------------------
revoke all on function public.ai_decide_and_act(uuid, numeric, timestamptz) from public, anon, authenticated;
revoke all on function public.run_ai_policy_worker(integer, numeric, timestamptz) from public, anon, authenticated;
grant execute on function public.ai_decide_and_act(uuid, numeric, timestamptz) to service_role;
grant execute on function public.run_ai_policy_worker(integer, numeric, timestamptz) to service_role;