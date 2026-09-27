-- FIX â€” OUT-parameter ambiguity (`status`) inside resolve_espionage_arrival (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- `status` is both an OUT parameter of the function and a column of fleet_movements, so the two guarded
-- transitions raised 42702 (ambiguous column reference). Their WHERE clauses are now qualified with a row
-- alias (`fm`); the SET targets stay unqualified, which is what PostgreSQL requires. The same fix applied to
-- the two deletes in `20260926124030` is preserved. No behaviour changes.

begin;

create or replace function public.resolve_espionage_arrival(p_fleet_id uuid)
returns table(fleet_id uuid, target_planet_id uuid, report_id uuid, status text, returns_at timestamp with time zone)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_fleet public.fleet_movements%rowtype;
    v_target public.planets%rowtype;
    v_report_id uuid;
    v_returns_at timestamp with time zone;
    v_duration interval;
    v_status text;
    v_esp integer := 0;
    v_target_esp integer := 0;
    v_probes_sent bigint := 0;
    v_probes_lost bigint := 0;
    v_defender_ships bigint := 0;
    v_chance integer := 0;
    v_triggered boolean := false;
    v_roll numeric;
    v_level_gap numeric := 0;
    v_remaining numeric := 0;
    v_reveal_ships boolean := true;
    v_reveal_defenses boolean := true;
    v_battle uuid;
    v_attacker_participant uuid;
    v_defender_participant uuid;
    v_survivors bigint := 0;
    v_attacker_name text;
    x record;
    n integer;
begin
    select fm.* into v_fleet
    from public.fleet_movements fm
    where fm.id = p_fleet_id
    for update;

    if not found then raise exception 'Fleet not found'; end if;
    if v_fleet.mission_type <> 'ESPIONAGE' then raise exception 'Fleet is not ESPIONAGE'; end if;
    if v_fleet.status <> 'ARRIVED' then raise exception 'Espionage must be ARRIVED'; end if;
    if v_fleet.destination_planet_id is null then raise exception 'Espionage has no target'; end if;

    select p.* into v_target
    from public.planets p
    where p.id = v_fleet.destination_planet_id and not p.is_destroyed
    for update;

    if not found then raise exception 'Target planet not found'; end if;

    perform public.update_planet_resources_until(v_target.id, v_fleet.arrives_at);
    perform public.process_shipyard_queue_until(v_target.id, v_fleet.arrives_at);
    perform public.process_defense_queue_until(v_target.id, v_fleet.arrives_at);

    v_esp := coalesce(public.get_player_research_level(v_fleet.player_id, 'espionage_technology'), 0);
    if v_target.player_id is not null then
        v_target_esp := coalesce(public.get_player_research_level(v_target.player_id, 'espionage_technology'), 0);
    end if;

    v_probes_sent := coalesce((select sum(fms.quantity)
                                 from public.fleet_movement_ships fms
                                where fms.fleet_id = p_fleet_id
                                  and fms.ship_id = 'espionage_probe'), 0);
    v_defender_ships := public.get_planet_defender_ship_count(v_target.id);
    v_chance := public.calculate_counter_espionage_chance(v_probes_sent, v_esp, v_target_esp, v_defender_ships);

    if v_chance > 0 then
        v_roll := floor(public.fleet_event_random(p_fleet_id, 'counter_espionage') * 100) + 1;
        v_triggered := v_roll <= v_chance;
    end if;

    if v_triggered and v_target.player_id is not null then
        insert into public.combat_battles(fleet_id, attacker_player_id, defender_planet_id,
            attacker_ships_before, attacker_ships_after, defender_ships_before, defender_ships_after,
            defender_defenses_before, defender_defenses_after, defender_combat_units_before,
            defender_combat_units_after, started_at)
        values (p_fleet_id, v_fleet.player_id, v_target.id, 0, 0, 0, 0, 0, 0, 0, 0, v_fleet.arrives_at)
        returning id into v_battle;

        insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
        values (v_battle, 'ATTACKER', 'FLEET', p_fleet_id, null, v_fleet.player_id, v_fleet.origin_planet_id, 'ESPIONAGE')
        returning id into v_attacker_participant;

        insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
        values (v_battle, 'DEFENDER', 'PLANET', null, v_target.id, v_target.player_id, null, 'ESPIONAGE')
        returning id into v_defender_participant;

        for x in select fms.ship_id, fms.quantity
                   from public.fleet_movement_ships fms
                  where fms.fleet_id = p_fleet_id and fms.quantity > 0
                  order by fms.ship_id
        loop
            for n in 1..x.quantity loop
                insert into public.combat_individual_units(battle_id, round_number, participant_id, side, unit_type,
                    unit_id, unit_number, attack, shield_max, shield_current, structural_integrity, hull_max, hull_current, alive)
                values (v_battle, 1, v_attacker_participant, 'ATTACKER', 'SHIP', x.ship_id, n,
                        public.get_combat_ship_attack(v_fleet.player_id, x.ship_id),
                        public.get_combat_ship_shield(v_fleet.player_id, x.ship_id),
                        public.get_combat_ship_shield(v_fleet.player_id, x.ship_id),
                        public.get_combat_ship_hull(v_fleet.player_id, x.ship_id) * 10,
                        public.get_combat_ship_hull(v_fleet.player_id, x.ship_id),
                        public.get_combat_ship_hull(v_fleet.player_id, x.ship_id), true);
            end loop;
        end loop;

        for x in select ps.ship_id, ps.quantity
                   from public.planet_ships ps
                  where ps.planet_id = v_target.id and ps.quantity > 0
                  order by ps.ship_id
        loop
            for n in 1..x.quantity loop
                insert into public.combat_individual_units(battle_id, round_number, participant_id, side, unit_type,
                    unit_id, unit_number, attack, shield_max, shield_current, structural_integrity, hull_max, hull_current, alive)
                values (v_battle, 1, v_defender_participant, 'DEFENDER', 'SHIP', x.ship_id, n,
                        public.get_combat_ship_attack(v_target.player_id, x.ship_id),
                        public.get_combat_ship_shield(v_target.player_id, x.ship_id),
                        public.get_combat_ship_shield(v_target.player_id, x.ship_id),
                        public.get_combat_ship_hull(v_target.player_id, x.ship_id) * 10,
                        public.get_combat_ship_hull(v_target.player_id, x.ship_id),
                        public.get_combat_ship_hull(v_target.player_id, x.ship_id), true);
            end loop;
        end loop;

        update public.combat_battles cb
           set attacker_ships_before = (select count(*) from public.combat_individual_units u
                                         where u.battle_id = v_battle and u.side = 'ATTACKER'),
               attacker_ships_after  = (select count(*) from public.combat_individual_units u
                                         where u.battle_id = v_battle and u.side = 'ATTACKER'),
               defender_ships_before = (select count(*) from public.combat_individual_units u
                                         where u.battle_id = v_battle and u.side = 'DEFENDER'),
               defender_ships_after  = (select count(*) from public.combat_individual_units u
                                         where u.battle_id = v_battle and u.side = 'DEFENDER'),
               defender_combat_units_before = (select count(*) from public.combat_individual_units u
                                                where u.battle_id = v_battle and u.side = 'DEFENDER'),
               defender_combat_units_after  = (select count(*) from public.combat_individual_units u
                                                where u.battle_id = v_battle and u.side = 'DEFENDER')
         where cb.id = v_battle;



        perform public.run_expedition_combat(v_battle);

        /* surviving attacker units (probes and anything else the fleet carried) */
        delete from public.fleet_movement_ships fms where fms.fleet_id = p_fleet_id;

        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        select p_fleet_id, q.unit_id, q.quantity
        from (select u.unit_id, count(*)::bigint as quantity
                from public.combat_individual_units u
               where u.battle_id = v_battle
                 and u.side = 'ATTACKER'
                 and u.alive
                 and u.round_number = (select max(m.round_number) from public.combat_individual_units m
                                        where m.battle_id = v_battle and m.side = 'ATTACKER')
               group by u.unit_id) q;

        /* surviving defender ships (defence structures never took part) */
        delete from public.planet_ships ps
         where ps.planet_id = v_target.id
           and exists (select 1 from public.combat_individual_units u
                        where u.battle_id = v_battle and u.side = 'DEFENDER' and u.unit_id = ps.ship_id);

        insert into public.planet_ships(planet_id, ship_id, quantity)
        select v_target.id, q.unit_id, q.quantity
        from (select u.unit_id, count(*)::bigint as quantity
                from public.combat_individual_units u
               where u.battle_id = v_battle
                 and u.side = 'DEFENDER'
                 and u.alive
                 and u.round_number = (select max(m.round_number) from public.combat_individual_units m
                                        where m.battle_id = v_battle and m.side = 'DEFENDER')
               group by u.unit_id) q
        on conflict (planet_id, ship_id) do update set quantity = excluded.quantity;

        /* destroyed probes and defender ships leave debris at the TARGET coordinates (OGameX parity) */
        perform public.create_combat_debris(v_battle);
    end if;

    v_probes_lost := greatest(0, v_probes_sent - coalesce((select sum(fms.quantity)
                                                            from public.fleet_movement_ships fms
                                                           where fms.fleet_id = p_fleet_id
                                                             and fms.ship_id = 'espionage_probe'), 0));

    /* OGameX reveal rule (EspionageMission::canRevealData) */
    v_level_gap := greatest(0, v_target_esp - v_esp);
    v_remaining := greatest(0, v_probes_sent - power(v_level_gap, 2));
    v_reveal_ships := v_remaining >= 2 or (v_esp - 1) >= v_target_esp;
    v_reveal_defenses := v_remaining >= 3 or (v_esp - 2) >= v_target_esp;


    /* The report row is keyed by fleet_id, so a replay refreshes it instead of duplicating it. */
    insert into public.espionage_reports(fleet_id, player_id, target_planet_id, espionage_level,
        target_espionage_level, metal, crystal, deuterium, energy, fleet, defenses,
        counter_espionage_chance, counter_espionage_triggered, probes_sent, probes_lost)
    select v_fleet.id, v_fleet.player_id, v_target.id, v_esp, v_target_esp,
           pr.metal, pr.crystal, pr.deuterium,
           coalesce((select sum(ps.quantity * sd.attack)
                       from public.planet_ships ps
                       join public.ship_definitions sd on sd.id = ps.ship_id
                      where ps.planet_id = v_target.id), 0),
           case when v_reveal_ships
                then coalesce((select jsonb_object_agg(ps.ship_id, ps.quantity)
                                 from public.planet_ships ps
                                where ps.planet_id = v_target.id), '{}'::jsonb)
                else '{}'::jsonb end,
           case when v_reveal_defenses
                then coalesce((select jsonb_object_agg(pd.defense_id, pd.quantity)
                                 from public.planet_defenses pd
                                where pd.planet_id = v_target.id), '{}'::jsonb)
                else '{}'::jsonb end,
           v_chance, v_triggered, v_probes_sent, v_probes_lost
    from public.planet_resources pr
    where pr.planet_id = v_target.id
    on conflict on constraint espionage_reports_fleet_id_key do update
        set created_at = clock_timestamp(),
            espionage_level = excluded.espionage_level,
            target_espionage_level = excluded.target_espionage_level,
            metal = excluded.metal,
            crystal = excluded.crystal,
            deuterium = excluded.deuterium,
            energy = excluded.energy,
            fleet = excluded.fleet,
            defenses = excluded.defenses,
            counter_espionage_chance = excluded.counter_espionage_chance,
            counter_espionage_triggered = excluded.counter_espionage_triggered,
            probes_sent = excluded.probes_sent,
            probes_lost = excluded.probes_lost
    returning public.espionage_reports.id into v_report_id;

    v_survivors := coalesce((select sum(fms.quantity)
                               from public.fleet_movement_ships fms
                              where fms.fleet_id = p_fleet_id), 0);

    if v_survivors > 0 then
        v_duration := v_fleet.arrives_at - v_fleet.started_at;
        v_returns_at := v_fleet.arrives_at + v_duration;

        update public.fleet_movements fm
        set status = 'RETURNING', returns_at = v_returns_at
        where fm.id = p_fleet_id and fm.status = 'ARRIVED';

        v_status := 'RETURNING';
    else
        /* Every unit died (counter-espionage wiped the flight): no ghost return, no ghost ships. */
        delete from public.fleet_movement_ships fms where fms.fleet_id = p_fleet_id;

        update public.fleet_movements fm
        set status = 'COMPLETED', returns_at = null
        where fm.id = p_fleet_id and fm.status = 'ARRIVED';

        v_returns_at := null;
        v_status := 'COMPLETED';
    end if;

    /* Messages (a messaging failure must never break the espionage resolution itself). */
    begin
        perform public.create_player_message(
            v_fleet.player_id, null, 'Espionage report',
            format('Your espionage flight over %s (chance of detection %s%%) produced a report.',
                   public.format_coordinates(v_target.galaxy, v_target.system, v_target.position), v_chance),
            'espionage_report:' || p_fleet_id::text);

        if v_status = 'COMPLETED' then
            perform public.create_player_message(
                v_fleet.player_id, null, 'Fleet lost contact',
                format('Your espionage flight over %s was destroyed by counter-espionage: %s probes lost.',
                       public.format_coordinates(v_target.galaxy, v_target.system, v_target.position), v_probes_lost),
                'fleet_lost_contact:' || p_fleet_id::text);
        end if;
    exception when others then
        raise warning 'MESSAGE_PRODUCER_FAILED espionage=% error=%', p_fleet_id, sqlerrm;
    end;

    if v_target.player_id is not null then
        select pl.username into v_attacker_name from public.players pl where pl.id = v_fleet.player_id;

        begin
            perform public.create_player_message(
                v_target.player_id, null, 'You were espied',
                format('%s espied %s. Counter-espionage chance: %s%%.%s',
                       coalesce(v_attacker_name, 'An unknown player'),
                       public.format_coordinates(v_target.galaxy, v_target.system, v_target.position),
                       v_chance,
                       case when v_triggered then ' Your ships engaged the probes.' else '' end),
                'espionage_detected:' || p_fleet_id::text);
        exception when others then
            raise warning 'MESSAGE_PRODUCER_FAILED espionage_defender=% error=%', p_fleet_id, sqlerrm;
        end;
    end if;

    fleet_id := v_fleet.id;
    target_planet_id := v_target.id;
    report_id := v_report_id;
    status := v_status;
    returns_at := v_returns_at;
    return next;
end;
$function$;

comment on function public.resolve_espionage_arrival(uuid) is
$c$The only espionage write path. Settles the target planet to the arrival instant, computes the OGameX
counter-espionage chance, rolls it deterministically (replay-safe), and — when triggered — runs a real battle of the
probe fleet against the target's SHIPS through the existing combat engine, writing losses back to
fleet_movement_ships / planet_ships and creating debris at the target. Report contents are gated by the OGameX reveal
rule. Messages: espionage report (attacker), fleet lost contact (attacker, all probes destroyed), you were espied
(defender). Idempotent by fleet_id; the movement returns with the persisted outbound duration, or goes to COMPLETED
when nothing survived.$c$;

revoke all on function public.resolve_espionage_arrival(uuid) from public, anon, authenticated;
grant execute on function public.resolve_espionage_arrival(uuid) to service_role;

commit;

