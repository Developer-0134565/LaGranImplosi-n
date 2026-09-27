-- MOON ENGINE FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Contract (20260926130000/…30100/…30200/…30800): moon identity, one moon per planet, creation from battle debris,
-- lunar-base field capacity, building kind gating + research prerequisite, moon destruction, coordinate lookups.
-- LIMITATION: single-session harness; concurrency not executed.

begin;

drop table if exists t_moon;
create temp table t_moon(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_planet uuid; v_universe uuid; v_other uuid;
    v_galax integer; v_sys integer; v_pos integer;
    v_moon uuid; v_battle uuid; v_fleet uuid;
    v_part uuid; v_part_def uuid; v_debris uuid; v_diameter integer;
    v_ok boolean; v_fail integer := 0; v_rows integer; v_raised text; v_roll integer;
    v_fields integer; v_attempt integer; v_msg integer; v_n integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id, p.galaxy, p.system, p.position into v_planet, v_galax, v_sys, v_pos
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
      order by p.created_at limit 1;
    select pl.id into v_other from public.players pl where pl.id <> v_player order by pl.created_at limit 1;

    if v_player is null or v_planet is null or v_other is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a second player are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 60)
    on conflict (player_id, research_id) do update set level = 60;

    delete from public.planets m where m.parent_planet_id = v_planet;
    delete from public.player_messages where recipient_player_id = v_player and dedupe_key is not null;

    v_ok := public.calculate_moon_creation_chance(99999) = 0
            and public.calculate_moon_creation_chance(100000) = 1
            and public.calculate_moon_creation_chance(1999999) = 19
            and public.calculate_moon_creation_chance(2000000) = 20
            and public.calculate_moon_creation_chance(90000000) = 20;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '1. chance = floor(debris/100000) clamped at the OGame maximum of 20 %');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
            is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
        values (v_universe, v_player, 'Bad Moon', v_galax + 1, v_sys, v_pos, 1, 0, false, false,
                'MOON', v_planet, 2000);
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'MOON_MUST_SHARE_PARENT_COORDINATES%';
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. a moon must share its planet coordinates (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
            is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
        values (v_universe, v_other, 'Foreign Moon', v_galax, v_sys, v_pos, 1, 0, false, false,
                'MOON', v_planet, 2000);
    exception when others then
        v_raised := sqlerrm;
    end;

    select count(*)::integer into v_rows from public.planets p where p.parent_planet_id = v_planet;
    v_ok := v_raised like 'MOON_OWNER_MUST_MATCH_PARENT%' and v_rows = 0;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a moon follows its planet owner (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    values (v_universe, v_player, 'Moon', v_galax, v_sys, v_pos, -20, 20, 1, 0, false, false, 'MOON', v_planet, 2000)
    returning id into v_moon;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_moon, 0, 0, 0, 0, clock_timestamp()) on conflict (planet_id) do nothing;

    select count(*)::integer into v_rows from public.planets p
     where p.universe_id = v_universe and p.galaxy = v_galax and p.system = v_sys and p.position = v_pos;
    v_ok := v_moon is not null and v_rows = 2;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. moon and planet coexist at the same coordinates (%s rows)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        insert into public.planets(universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
            is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
        values (v_universe, v_player, 'Second Moon', v_galax, v_sys, v_pos, 1, 0, false, false, 'MOON', v_planet, 2000);
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised is not null;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a second moon for the same planet is refused (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.planet_buildings(planet_id, building_id, level) values (v_moon, 'lunar_base', 3)
    on conflict (planet_id, building_id) do update set level = 3;

    select p.fields_total into v_fields from public.planets p where p.id = v_moon;
    v_ok := v_fields = public.calculate_moon_field_capacity(3) and v_fields = 10;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. lunar base level 3 sets the moon capacity to %s fields (1 + 3 x level)', v_fields));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_raised := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        values (v_planet, 'lunar_base', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', 'QUEUED');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'BUILDING_NOT_AVAILABLE_FOR_KIND%';
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. a moon building cannot be queued on a planet (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    delete from public.player_research where player_id = v_player and research_id = 'hyperspace_technology';

    v_raised := null;
    begin
        insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
        values (v_moon, 'jump_gate', 1, clock_timestamp(), clock_timestamp() + interval '1 hour', 'QUEUED');
    exception when others then
        v_raised := sqlerrm;
    end;

    v_ok := v_raised like 'BUILDING_RESEARCH_PREREQUISITES_NOT_MET%';
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. the jump gate needs hyperspace_technology 7 (%s)', coalesce(v_raised, 'no error')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;



    /* 9/10. moon creation from a battle: 6 667 destroyed probes → 2 000 100 debris → chance 20.
       The deterministic roll is a pure function of the fleet timestamps, so the fixture SEARCHES a favourable
       dispatch instant (failing after 400 attempts would need 0.8^400). */
    delete from public.planets where id = v_moon;

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position)
    values (v_player, v_planet, v_planet, 'ATTACK', clock_timestamp() - interval '1 hour',
        clock_timestamp() + interval '1 hour', 'OUTBOUND', v_galax, v_sys, v_pos)
    returning id into v_fleet;

    v_n := 0;
    loop
        v_roll := floor(public.fleet_event_random(v_fleet, 'moon_creation') * 100) + 1;
        exit when v_roll <= 20;
        v_n := v_n + 1;
        update public.fleet_movements set arrives_at = arrives_at + interval '1 second' where id = v_fleet;
        if v_n > 400 then
            raise exception 'MOON_FIXTURE: no favourable moon roll inside 400 attempts';
        end if;
    end loop;

    insert into public.combat_battles(fleet_id, attacker_player_id, defender_planet_id, attacker_ships_before,
        attacker_ships_after, defender_ships_before, defender_ships_after, defender_defenses_before,
        defender_defenses_after, defender_combat_units_before, defender_combat_units_after, draw, started_at)
    values (v_fleet, v_player, v_planet, 0, 0, 0, 0, 0, 0, 0, 0, true, clock_timestamp())
    returning id into v_battle;

    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
    values (v_battle, 'ATTACKER', 'FLEET', v_fleet, null, v_player, v_planet, 'ATTACK')
    returning id into v_part;

    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
    values (v_battle, 'DEFENDER', 'PLANET', null, v_planet, v_player, null, 'ATTACK')
    returning id into v_part_def;

    insert into public.combat_individual_units(battle_id, round_number, participant_id, side, unit_type, unit_id,
        unit_number, attack, shield_max, shield_current, structural_integrity, hull_max, hull_current, alive)
    select v_battle, 1, v_part, 'ATTACKER', 'SHIP', 'espionage_probe', g, 0, 0, 0, 1000, 100, 100, false
      from generate_series(1, 6667) g;

    insert into public.debris_fields(universe_id, galaxy, system, position, metal, crystal)
    values (v_universe, v_galax, v_sys, v_pos, 0, 0) returning id into v_debris;

    /* the insert below fires the real creation hook */
    insert into public.combat_debris_generations(battle_id, debris_field_id, metal_generated, crystal_generated)
    values (v_battle, v_debris, 0, 2000100);

    select m.id, m.moon_diameter_km into v_moon, v_diameter
      from public.planets m where m.parent_planet_id = v_planet and not m.is_destroyed;

    v_ok := v_moon is not null
            and v_diameter = least(8944, floor(sqrt(10 + floor(public.fleet_event_random(v_fleet, 'moon_x_factor') * 11)
                   + (3 * 2000100 / 100000)) * 1000));
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. the debris of a battle created a moon of %s km (OGameX diameter formula)', v_diameter));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_attempt
      from public.moon_creation_rolls r
     where r.battle_id = v_battle and r.moon_chance = 20 and r.roll <= 20 and r.moon_id = v_moon;
    select count(*)::integer into v_msg
      from public.player_messages pm where pm.dedupe_key = 'moon_created:' || v_moon::text;
    select count(*)::integer into v_rows from public.planet_resources pr where pr.planet_id = v_moon;
    select m.fields_total into v_fields from public.planets m where m.id = v_moon;

    v_ok := v_attempt = 1 and v_msg = 1 and v_rows = 1 and v_fields = 1
            and exists (select 1 from public.planets m where m.id = v_moon and m.kind = 'MOON'
                        and m.galaxy = v_galax and m.system = v_sys and m.position = v_pos
                        and m.player_id = v_player and not m.is_homeworld);
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. creation provenance/chance/message/resources/identity/fields (%s/%s/%s/%s)',
             v_attempt, v_msg, v_rows, v_fields));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 11. moon destruction: 1 Deathstar against a 2 000 km moon → success chance 55 %, searched favourable roll */
    update public.planets m set moon_diameter_km = 2000 where m.id = v_moon;
    insert into public.planet_ships(planet_id, ship_id, quantity) values (v_moon, 'light_fighter', 10)
    on conflict (planet_id, ship_id) do update set quantity = 10;

    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at,
        arrives_at, status, destination_galaxy, destination_system, destination_position)
    values (v_player, v_planet, v_moon, 'ATTACK', clock_timestamp() - interval '1 hour',
        clock_timestamp() + interval '1 hour', 'OUTBOUND', v_galax, v_sys, v_pos)
    returning id into v_fleet;

    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'deathstar', 1);

    v_n := 0;
    loop
        v_roll := floor(public.fleet_event_random(v_fleet, 'moon_destruction') * 100) + 1;
        exit when v_roll <= 55;
        v_n := v_n + 1;
        update public.fleet_movements set arrives_at = arrives_at + interval '1 second' where id = v_fleet;
        if v_n > 400 then
            raise exception 'MOON_FIXTURE: no favourable destruction roll inside 400 attempts';
        end if;
    end loop;

    insert into public.combat_battles(fleet_id, attacker_player_id, defender_planet_id, attacker_ships_before,
        attacker_ships_after, defender_ships_before, defender_ships_after, defender_defenses_before,
        defender_defenses_after, defender_combat_units_before, defender_combat_units_after, draw, started_at)
    values (v_fleet, v_player, v_moon, 0, 0, 0, 0, 0, 0, 0, 0, true, clock_timestamp())
    returning id into v_battle;

    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
    values (v_battle, 'ATTACKER', 'FLEET', v_fleet, null, v_player, v_planet, 'ATTACK');

    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
    values (v_battle, 'DEFENDER', 'PLANET', null, v_moon, v_player, null, 'ATTACK');

    /* finishing the battle fires the destruction hook */
    update public.combat_battles set finished_at = clock_timestamp() where id = v_battle;

    select count(*)::integer into v_rows
      from public.moon_destruction_attempts a
     where a.battle_id = v_battle and a.moon_id = v_moon and a.success_chance = 55
       and a.roll <= 55 and a.destroyed and a.deathstars_lost = 0;
    select count(*)::integer into v_msg
      from public.player_messages pm where pm.dedupe_key = 'moon_destruction:' || v_battle::text;

    v_ok := v_rows = 1 and v_msg = 1
            and exists (select 1 from public.planets m where m.id = v_moon and m.is_destroyed and m.fields_total = 0)
            and not exists (select 1 from public.planet_ships ps where ps.planet_id = v_moon)
            and not exists (select 1 from public.planet_buildings pb where pb.planet_id = v_moon)
            and exists (select 1 from public.debris_fields df
                         where df.universe_id = v_universe and df.galaxy = v_galax and df.system = v_sys
                           and df.position = v_pos and df.metal > 0);
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. a successful attempt destroys the moon, empties it into debris and keeps its row (%s/%s)',
             v_rows, v_msg));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 12. every coordinate lookup that means "a planet" filters kind = 'PLANET' */
    select count(*)::integer into v_rows
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('start_colonize_fleet', 'resolve_colonize_arrival', 'provision_player',
                         'reconcile_universe_ai_population')
       and p.prosrc like '%kind%PLANET%';

    v_ok := v_rows = 4;
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. the four coordinate lookups filter kind = ''PLANET'' (%s/4)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* 13. ACL: the moon settlement helpers stay internal */
    v_ok := not has_function_privilege('authenticated', 'public.settle_moon_creation_for_battle(uuid)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.settle_moon_destruction_for_battle(uuid)', 'EXECUTE')
            and has_function_privilege('authenticated', 'public.get_player_moons()', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_moons()', 'EXECUTE');
    insert into t_moon(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. ACL: settlement helpers internal, moon overview readable by its owner');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_moon(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. The roll is deterministic by design, which is why the fixture can search a favourable dispatch instant instead of faking randomness.');

    if v_fail > 0 then
        raise exception 'MOON ENGINE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_moon order by orden;

drop table if exists t_moon;

ROLLBACK;

