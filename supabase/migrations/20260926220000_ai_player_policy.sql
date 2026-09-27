-- =====================================================================
-- AI PLAYER POLICY (owner-approved 2026-09-26) â€” LGI
-- =====================================================================
-- OGameX has NO player-AI policy: its only NPC code is NpcFleetGenerator, which builds balanced *enemy fleets*
-- for expeditions/battles. There is no reference policy to port, and the owner explicitly authorised LGI to
-- define one. This policy is LGI's own and deliberately explicit:
--
--   One action per AI player per tick, first allowed wins:
--     1. ENERGY   â€” solar_plant when the planet has no positive energy margin.
--     2. ECONOMY  â€” the lowest level among metal_mine / crystal_mine / deuterium_synthesizer.
--     3. RESEARCH â€” a fixed ordered list led by energy_technology, combustion_drive, espionage_technology,
--                   computer_technology and astrophysics (the colony-cap lever).
--     4. COLONY   â€” only when check_colony_cap() allows it and a colony ship is available.
--
--   Budget rules (balanced, the AI can not bankrupt itself):
--     * an action may cost at most `p_budget_percent` (default 60 %) of each stored resource;
--     * a deuterium floor (1000) is always preserved for fleet fuel;
--     * the queue rules of the certified dispatchers apply unchanged.
--
--   Every action uses the SAME certified authorities as a human player
--   (`can_start_building`/`start_building`, `can_start_research`/`start_research`, `start_colonize_fleet`)
--   inside the certified service actor contract (`ai_actor_begin`/`ai_actor_end`).
--   Expeditions/transports are the next increment (fleet mission semantics need their own fixture).
-- =====================================================================

create or replace function public.ai_decide_and_act(p_player_id uuid, p_budget_percent numeric default 60)
returns table(action text, target text, result text)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_planet uuid;
    v_universe uuid;
    v_prod record;
    v_can record;
    v_res record;
    v_building text;
    v_research text;
    v_i integer;
    v_ship bigint;
    v_g integer;
    v_s integer;
    v_p integer;
    v_cap record;
    v_free boolean := false;
begin
    if p_budget_percent is null or p_budget_percent <= 0 or p_budget_percent > 100 then
        raise exception 'AI_BUDGET_INVALID: %', p_budget_percent;
    end if;

    select p.id, p.universe_id into v_planet, v_universe
      from public.planets p
     where p.player_id = p_player_id and p.kind = 'PLANET' and p.is_destroyed = false
     order by p.is_homeworld desc, p.created_at
     limit 1;

    if v_planet is null then
        action := 'none'; target := null; result := 'AI_NO_PLANET';
        return next; return;
    end if;

    select * into v_res from public.planet_resources pr where pr.planet_id = v_planet;
    select * into v_prod from public.calculate_planet_production(v_planet);

    if coalesce(v_prod.energy_per_hour, 0) <= 0 then
        v_building := 'solar_plant';
    else
        select b.id into v_building
          from unnest(array['metal_mine', 'crystal_mine', 'deuterium_synthesizer']) as b(id)
          left join public.planet_buildings pb on pb.planet_id = v_planet and pb.building_id = b.id
          order by coalesce(pb.level, 0), b.id
          limit 1;
    end if;

    select * into v_can from public.can_start_building(p_player_id, v_planet, v_building) limit 1;
    if coalesce(v_can.allowed, false)
       and coalesce(v_can.cost_metal, 0) <= coalesce(v_res.metal, 0) * p_budget_percent / 100
       and coalesce(v_can.cost_crystal, 0) <= coalesce(v_res.crystal, 0) * p_budget_percent / 100
       and coalesce(v_can.cost_deuterium, 0) <= greatest(0, coalesce(v_res.deuterium, 0) - 1000) * p_budget_percent / 100
    then
        perform public.start_building(p_player_id, v_planet, v_building);
        action := 'building'; target := v_building; result := 'STARTED';
        return next; return;
    end if;

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
            perform public.start_research(p_player_id, v_planet, v_research);
            action := 'research'; target := v_research; result := 'STARTED';
            return next; return;
        end if;
    end loop;

    select * into v_cap from public.check_colony_cap(p_player_id) limit 1;
    select coalesce(sum(ps.quantity), 0) into v_ship
      from public.planet_ships ps where ps.planet_id = v_planet and ps.ship_id = 'colony_ship';

    if coalesce(v_cap.allowed, false) and v_ship > 0 then
        select p.galaxy into v_g from public.planets p where p.id = v_planet;
        for v_i in 1..30 loop
            v_s := 1 + ((v_i - 1) % 10);
            v_p := 5 + ((v_i - 1) / 10);
            v_free := not exists (select 1 from public.planets p
                                   where p.universe_id = v_universe and p.galaxy = v_g and p.system = v_s
                                     and p.position = v_p and p.kind = 'PLANET' and p.is_destroyed = false);
            if v_free then
                exit;
            end if;
        end loop;

        if v_free then
            perform public.start_colonize_fleet(p_player_id, v_planet, v_g, v_s, v_p);
            action := 'colony'; target := v_g || ':' || v_s || ':' || v_p; result := 'STARTED';
            return next; return;
        end if;
    end if;

    action := 'none'; target := null; result := 'AI_IDLE';
    return next;
end;
$function$;

-- ---------------------------------------------------------------------
-- Worker: one action per AI player per tick, inside the certified service actor contract.
-- A failing player is isolated (sub-transaction) so the batch always completes.
-- ---------------------------------------------------------------------
create or replace function public.run_ai_policy_worker(p_max_players integer default 25, p_budget_percent numeric default 60)
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
            select * into v_decision from public.ai_decide_and_act(v_player.id, p_budget_percent);
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

revoke all on function public.ai_decide_and_act(uuid, numeric) from public;
revoke all on function public.run_ai_policy_worker(integer, numeric) from public;

grant execute on function public.ai_decide_and_act(uuid, numeric) to service_role;
grant execute on function public.run_ai_policy_worker(integer, numeric) to service_role;

-- Scheduling (idempotent): every 5 minutes, like the ranking worker.
select cron.unschedule(jobid) from cron.job where jobname = 'lagranimplosion-ai-policy';
select cron.schedule(
    'lagranimplosion-ai-policy',
    '*/5 * * * *',
    'select public.run_ai_policy_worker();'
);
