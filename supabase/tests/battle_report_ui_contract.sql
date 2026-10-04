-- BATTLE REPORT UI CONTRACT FIXTURE - LA GRAN IMPLOSION
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test: `get_player_battle_reports(p_limit)` - the ONLY read path of the new
-- `BattleReportsPanel` (src/GameplayEnginePanel.tsx, rendered by the Messages view in src/App.tsx).
--
-- Gap closed 2026-09-28 (Messages/Reports cycle): the contract has always exposed `rounds`
-- (per-round unit counts) and `participants`, but the browser never consumed them - the COMBATE row
-- of the communications centre was a one-line summary. This fixture certifies the payload the
-- panel actually renders, plus the ownership chain and the ACL behind it. It does NOT assert a
-- browser render: the panel is READ-ONLY, so a DOM assertion would only test the
-- implementation, not the contract.
--
-- LIMITATION: single-session harness; concurrency not executed. LIVE carries a single auth
-- player, so the foreign caller is created inside this transaction: the assertion under test is
-- the CONTRACT isolation, not the environment's data.

begin;

drop table if exists t_bui;
create temp table t_bui(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_other uuid; v_other_user uuid;
    v_planet uuid; v_fleet uuid; v_battle uuid; v_part uuid; v_part_def uuid; v_debris uuid;
    v_galax integer; v_sys integer; v_pos integer;
    v_ok boolean; v_fail integer := 0; v_rows integer;
    v_rounds jsonb; v_parts jsonb; v_losses jsonb; v_outcome text; v_role text; v_played integer;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id, p.galaxy, p.system, p.position into v_planet, v_galax, v_sys, v_pos
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    v_other_user := gen_random_uuid();
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token)
    values (v_other_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'buiforeign@example.invalid', crypt('Buiforeign!1', gen_salt('bf')), clock_timestamp(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, clock_timestamp(), clock_timestamp(), '', '');
    insert into public.players(user_id, universe_id, username, is_guest, player_type)
    values (v_other_user, v_universe, 'BuiForeign', false, 'HUMAN') returning id into v_other;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_planet, v_planet, 'ATTACK', clock_timestamp() - interval '1 hour', clock_timestamp() + interval '1 hour', 'COMPLETED')
    returning id into v_fleet;
    insert into public.combat_battles(fleet_id, attacker_player_id, defender_planet_id, attacker_ships_before, attacker_ships_after,
        defender_ships_before, defender_ships_after, defender_defenses_before, defender_defenses_after,
        defender_combat_units_before, defender_combat_units_after, attacker_win, defender_win, draw, started_at, finished_at)
    values (v_fleet, v_player, v_planet, 10, 6, 0, 0, 4, 1, 4, 1, true, false, false, clock_timestamp(), clock_timestamp())
    returning id into v_battle;
    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, origin_planet_id, mission_type)
    values (v_battle, 'ATTACKER', 'FLEET', v_fleet, null, v_player, v_planet, 'ATTACK') returning id into v_part;
    insert into public.combat_battle_participants(battle_id, side, participant_type, fleet_id, planet_id, player_id, mission_type)
    values (v_battle, 'DEFENDER', 'PLANET', null, v_planet, v_player, 'ATTACK') returning id into v_part_def;
    insert into public.combat_rounds(battle_id, round_number, attacker_attack, attacker_shield, attacker_hull,
        defender_attack, defender_shield, defender_hull, attacker_units_before, attacker_units_after,
        defender_units_before, defender_units_after, defender_combat_units_before, defender_combat_units_after)
    values (v_battle, 1, 100, 10, 100, 50, 20, 100, 10, 8, 4, 2, 4, 2),
           (v_battle, 2, 100, 10, 100, 50, 20, 100, 8, 6, 2, 0, 2, 1);
    insert into public.combat_individual_units(battle_id, round_number, participant_id, side, unit_type, unit_id,
        unit_number, attack, shield_max, shield_current, structural_integrity, hull_max, hull_current, alive)
    select v_battle, 1, v_part, 'ATTACKER', 'SHIP', 'light_fighter', g, 50, 10, 10, 100, 10, 10,
           case when g <= 8 then true else false end from generate_series(1, 10) g;
    insert into public.combat_individual_units(battle_id, round_number, participant_id, side, unit_type, unit_id,
        unit_number, attack, shield_max, shield_current, structural_integrity, hull_max, hull_current, alive)
    select v_battle, 1, v_part_def, 'DEFENDER', 'DEFENSE', 'rocket_launcher', g, 40, 10, 10, 100, 10, 10,
           case when g <= 1 then true else false end from generate_series(1, 4) g;
    insert into public.debris_fields(universe_id, galaxy, system, position, metal, crystal)
    values (v_universe, v_galax, v_sys, v_pos, 0, 0) returning id into v_debris;
    insert into public.combat_debris_generations(battle_id, debris_field_id, metal_generated, crystal_generated)
    values (v_battle, v_debris, 1200, 300);
    select r.outcome, r.caller_role, r.rounds_played, r.rounds, r.participants, r.losses
      into v_outcome, v_role, v_played, v_rounds, v_parts, v_losses
      from public.get_player_battle_reports(25) r where r.battle_id = v_battle;
    v_ok := v_outcome = 'ATTACKER_WIN' and v_role = 'ATTACKER' and v_played = 2
            and jsonb_array_length(v_rounds) = 2 and jsonb_array_length(v_parts) = 2
            and jsonb_array_length(v_losses) = 2;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. the owner retrieves the whole payload: outcome %s, role %s, %s rounds, %s participants, %s loss rows',
             coalesce(v_outcome,'-'), coalesce(v_role,'-'), coalesce(jsonb_array_length(v_rounds)::text,'-'),
             coalesce(jsonb_array_length(v_parts)::text,'-'), coalesce(jsonb_array_length(v_losses)::text,'-')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    select jsonb_agg(jsonb_build_object('n', (e.value->>'round')::int, 'ab', (e.value->>'attacker_units_before')::int,
               'aa', (e.value->>'attacker_units_after')::int, 'db', (e.value->>'defender_units_before')::int,
               'da', (e.value->>'defender_units_after')::int, 'dcu', (e.value->>'defender_combat_units_after')::int)
             order by (e.value->>'round')::int)
      into v_rounds from jsonb_array_elements(v_rounds) e;
    v_ok := v_rounds @> '[{"n":1,"ab":10,"aa":8,"db":4,"da":2,"dcu":2},{"n":2,"ab":8,"aa":6,"db":2,"da":0,"dcu":1}]'::jsonb;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. round-by-round unit counts exposed exactly as stored: %s', coalesce(v_rounds::text,'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    select jsonb_agg(jsonb_build_object('side', p.value->>'side', 'ptype', p.value->>'participant_type')
             order by p.value->>'side', p.value->>'participant_type')
      into v_parts from jsonb_array_elements(v_parts) p;
    v_ok := v_parts @> '[{"side":"ATTACKER","ptype":"FLEET"},{"side":"DEFENDER","ptype":"PLANET"}]'::jsonb;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. participants exposed: %s', coalesce(v_parts::text,'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    select jsonb_agg(jsonb_build_object('side', l.value->>'side', 'type', l.value->>'unit_type',
               'id', l.value->>'unit_id', 'qty', (l.value->>'destroyed_quantity')::int)
             order by l.value->>'unit_id', l.value->>'unit_type')
      into v_losses from jsonb_array_elements(v_losses) l;
    v_ok := v_losses @> '[{"side":"ATTACKER","type":"SHIP","id":"light_fighter","qty":2}]'::jsonb
            and v_losses @> '[{"side":"DEFENDER","type":"DEFENSE","id":"rocket_launcher","qty":3}]'::jsonb;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. losses exposed for both sides: %s', coalesce(v_losses::text,'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_user::text)::text, true);
    select count(*)::integer into v_rows from public.get_player_battle_reports(50) r where r.battle_id = v_battle;
    v_ok := v_rows = 0;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a foreign authenticated player reads 0 rows of that battle (%s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', '{}', true);
    select count(*)::integer into v_rows from public.get_player_battle_reports(50) r where r.battle_id = v_battle;
    v_ok := v_rows = 0;
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. without a session the battle is invisible (%s rows)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    v_ok := has_function_privilege('authenticated', 'public.get_player_battle_reports(integer)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_battle_reports(integer)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_battle_reports(integer)', 'EXECUTE');
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. ACL unchanged: authenticated + service_role, anon denied');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    update public.combat_battles set finished_at = null where id = v_battle;
    select r.outcome into v_outcome from public.get_player_battle_reports(50) r where r.battle_id = v_battle;
    v_ok := v_outcome = 'UNRESOLVED';
    insert into t_bui(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. an unfinished battle is UNRESOLVED, not a win (%s)', coalesce(v_outcome,'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
    insert into t_bui(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency not executed. The panel is READ-ONLY, so this fixture proves the CONTRACT payload and the ownership chain it renders, not a browser render.');
    insert into t_bui(resultado, prueba) values ('INFO', format('SUMMARY: %s failed assertion(s).', v_fail));
    if v_fail > 0 then
        raise exception 'BATTLE REPORT UI CONTRACT: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_bui order by orden;

drop table if exists t_bui;

ROLLBACK;
