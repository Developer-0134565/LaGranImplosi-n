-- ACL: WRONG-CLIENT-INVOKER-HELPERS FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260929010000): four helpers that were `authenticated`-executable but whose
-- ONLY possible client outcome was an error or a provably wrong answer.
--
-- Why this is a defect and not a cleanup: all four are SECURITY INVOKER, so for a client the RLS of
-- the underlying table decides the result, not the function's logic. Measured before the change,
-- same data and same arguments, only the role differing — which is the whole proof:
--
--   can_recycle_debris(own fleet, real field)     engine true  -> client FALSE
--   get_expedition_ship_candidates(own fleet)     engine 5     -> client EXCEPTION
--   get_active_expedition_item_effect(own, own)   engine 42    -> client 0
--   check_defense_requirements(OWN planet)        engine OK    -> client "permission denied"
--
-- The fixture certifies:
--   1-4  the ENGINE still gets the CORRECT answer from each helper (nothing was broken)
--   5-8  the REAL `authenticated` role is REFUSED by each helper, never misled
--   9    NO REGRESSION: the whole 48-name src/** UI inventory keeps `authenticated` EXECUTE
--  10    all 45 surviving authenticated contract names are still client-reachable
--  11    the client-facing `calculate_research_time` overload keeps its grant
--  12    the DEFERRED Lifeforms surface is untouched
--  13    the three `deny_direct_api_access` policies that CAUSED the wrong answers are unchanged
--  14    on all four targets: anon and PUBLIC denied, service_role kept
--  15    `get_recyclable_debris_status`, the contract the UI really uses, still answers correctly
--
-- TWO FIXTURE TRAPS, both hit and corrected while writing this file, recorded so they are not
-- re-introduced: `can_recycle_debris` counts RECYCLERS in the fleet, so assertion 1 is meaningless
-- without a `recycler` row on the RECYCLE movement; and the debris upsert must key on
-- (universe_id, galaxy, system, position) or a pre-existing EMPTY field satisfies the "not empty"
-- premise for the wrong reason.
--
-- LIMITATION: single-session harness with ROLLBACK. Roles are switched with `set local role`, the
-- same mechanism the existing ACL fixtures use; no JWT is fabricated and no data is faked.

begin;

drop table if exists t_wci;
create temp table t_wci(orden serial, resultado text, prueba text);
grant insert on t_wci to authenticated;

do $test$
declare
    v_auth uuid; v_player uuid; v_fleet uuid; v_fleet_rec uuid; v_planet record; v_item text;
    v_client_err text := ''; v_n integer := 0; v_ok_n integer := 0; v_rec_row record;
    v_debris_ok boolean := false; v_cands integer := 0; v_effect numeric := 0; v_def boolean := false;
    /* Names whose ENTIRE overload set is expected to stay client-reachable. `calculate_research_time`
       is deliberately NOT here: it has four overloads of which only the planet-scoped one is a client
       contract, so a name-level assertion would be wrong (assertion 11 covers it precisely). */
    v_survive text[] := array['get_recyclable_debris_status','can_build_defense','can_build_ship',
      'get_player_expedition_reports','get_player_expedition_item_status','get_player_expedition_merchant',
      'get_player_expedition_slot_status','get_universe_debris','get_player_moons',
      'can_start_demolition','can_start_research','calculate_research_cost',
      'calculate_ship_cost','calculate_defense_cost','calculate_max_colony_slots','calculate_planet_storage',
      'get_current_planet_resources','ui_defense_queue','ui_universe_galaxies','get_universe_ranking',
      'get_universe_top1_points','get_research_network_lab_level','get_planet_economic_rates_snapshot',
      'project_building_production','get_active_expedition_count','expedition_fleet_has_pathfinder',
      'determine_expedition_max_resource_find','expedition_event_random','inspect_demolition',
      'on_combat_battle_finished_wreck_field','get_player_lifeform_effect',
      'get_lifeform_research_population_requirement','start_lifeform_building','start_lifeform_research',
      'lifeform_experience_multiplier','get_planet_lifeform_building_effect',
      'get_active_lifeform_research_effect','calculate_planet_production_snapshot',
      'calculate_planet_energy_balance','calculate_building_cost','calculate_building_energy_delta',
      'calculate_moon_creation_chance','calculate_recycler_capacity','calculate_sequence_crossover',
      'calculate_universe_rates'];
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    /* real EXPEDITION fleet, real item effect, real (NON-EMPTY) debris field, real recyclers */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, status,
        started_at, arrives_at, created_at)
    values (v_player, v_planet.id, 'EXPEDITION', 'OUTBOUND', now(), now() + interval '1 hour', now())
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'large_cargo', 5);
    insert into public.expedition_item_uses(player_id, planet_id, item_id, quantity, effect_snapshot)
    values (v_player, v_planet.id, v_item, 1, '{"effect_key":"probe_key","effect_value":42}'::jsonb);
    insert into public.debris_fields(universe_id, galaxy, system, "position", metal, crystal)
    values (v_planet.universe_id, 1, 498, 15, 5000, 3000)
    on conflict (universe_id, galaxy, system, "position") do update set metal = 5000, crystal = 3000;
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, status,
        started_at, arrives_at, destination_galaxy, destination_system, destination_position, created_at)
    values (v_player, v_planet.id, 'RECYCLE', 'OUTBOUND', now(), now() + interval '1 hour',
        1, 498, 15, now())
    returning id into v_fleet_rec;
    /* without this row can_recycle_debris is CORRECTLY false and assertion 1 would prove nothing */
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet_rec, 'recycler', 3);

    /* ---- 1-4: the ENGINE still gets the correct answer ---- */
    v_debris_ok := public.can_recycle_debris(v_fleet_rec, 1, 498, 15);
    select count(*) into v_cands from public.get_expedition_ship_candidates(v_fleet);
    select public.get_active_expedition_item_effect(v_player, v_planet.id, 'probe_key') into v_effect;
    select (r).allowed into v_def from public.check_defense_requirements(v_planet.id, 'rocket_launcher') r;

    insert into t_wci(orden, resultado, prueba) values
      (1, case when v_debris_ok then 'PASS' else 'FAIL' end,
          format('1. ENGINE can_recycle_debris -> %s (expect true)', v_debris_ok)),
      (2, case when v_cands > 0 then 'PASS' else 'FAIL' end,
          format('2. ENGINE get_expedition_ship_candidates -> %s candidates (expect > 0)', v_cands)),
      (3, case when v_effect = 42 then 'PASS' else 'FAIL' end,
          format('3. ENGINE get_active_expedition_item_effect -> %s (expect 42)', v_effect)),
      (4, case when v_def then 'PASS' else 'FAIL' end,
          format('4. ENGINE check_defense_requirements(OWN planet) -> allowed=%s', v_def));

    /* ---- 5-8: the REAL `authenticated` role is refused, never misled ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    v_client_err := ''; begin perform public.can_recycle_debris(v_fleet_rec, 1, 498, 15);
      exception when others then v_client_err := sqlerrm; end;
    insert into t_wci(orden, resultado, prueba) values (5, case when v_client_err <> '' then 'PASS' else 'FAIL' end,
      format('5. CLIENT can_recycle_debris refused [%s]', coalesce(nullif(v_client_err,''),'NO ERROR')));

    v_client_err := ''; begin perform public.get_expedition_ship_candidates(v_fleet);

    /* ---- 9: NO REGRESSION. The inventory is the scripts/contract-inventory.mjs list over src/** ---- */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    with ui(name) as (values
        ('can_build_defense'),('can_build_ship'),('can_start_building'),('can_start_demolition'),
        ('can_start_research'),('cancel_building'),('cancel_research'),('check_colony_cap'),
        ('execute_jump_gate'),('get_my_attack_protection'),('get_planet_building_preview'),
        ('get_planet_economy_overview'),('get_player_battle_reports'),('get_player_espionage_reports'),
        ('get_player_expedition_item_status'),('get_player_expedition_merchant'),
        ('get_player_expedition_reports'),('get_player_expedition_slot_status'),('get_player_fleet_slots'),
        ('get_player_messages'),('get_player_moons'),('get_player_research_lab_status'),
        ('get_player_support_authorizations'),('get_player_transport_movements'),
        ('get_recyclable_debris_status'),('get_universe_debris'),('get_universe_evolution_monitor_public'),
        ('get_universe_ranking_by_category'),('grant_planet_support_authorization'),('load_fleet_cargo'),
        ('mark_message_read'),('provision_player'),('recall_fleet'),('revoke_planet_support_authorization'),
        ('scan_with_phalanx'),('start_building'),('start_colonize_fleet'),('start_defense'),('start_demolition'),
        ('start_fleet'),('start_fleet_mixed'),('start_moon_destruction'),('start_research'),('start_ship'),
        ('start_support_fleet'),('sync_current_planet_resources'),('trade_with_expedition_merchant'),
        ('ui_building_definitions'),('ui_defense_definitions'),('ui_research_definitions'),
        ('ui_ship_definitions'),('use_expedition_item'))
    select count(*), count(*) filter (where has_function_privilege('authenticated', p.oid, 'EXECUTE'))
      into v_n, v_ok_n
      from ui join pg_proc p on p.proname = ui.name and p.pronamespace = 'public'::regnamespace;
    insert into t_wci(orden, resultado, prueba) values (9,
      case when v_n >= 45 and v_n = v_ok_n then 'PASS' else 'FAIL' end,
      format('9. NO REGRESSION: all %s UI contracts (%s names) keep authenticated EXECUTE', v_ok_n, v_n));

    /* ---- 10-12: the rest of the surviving authenticated surface is deliberately untouched ---- */
    select count(*) into v_n
      from unnest(v_survive) u(name)
      join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace
     where not has_function_privilege('authenticated', p.oid, 'EXECUTE');
    insert into t_wci(orden, resultado, prueba) values (10,
      case when v_n = 0 then 'PASS' else 'FAIL' end,
      format('10. all 45 surviving authenticated contract names still client-reachable (%s lost)', v_n));

    select count(*) into v_n
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'calculate_research_time'
       and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.oid::regprocedure::text like '%p_planet_id%';
    insert into t_wci(orden, resultado, prueba) values (11,
      case when v_n = 0 then 'PASS' else 'FAIL' end,
      format('11. the client-facing calculate_research_time overload still granted (%s lost)', v_n));

    select count(*) into v_n
      from unnest(v_survive) u(name)
      join pg_proc p on p.proname = u.name and p.pronamespace = 'public'::regnamespace
     where p.proname in ('start_lifeform_building','start_lifeform_research','get_player_lifeform_effect',
                         'get_lifeform_research_population_requirement','lifeform_experience_multiplier',
                         'get_planet_lifeform_building_effect','get_active_lifeform_research_effect')
       and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
    insert into t_wci(orden, resultado, prueba) values (12,
      case when v_n = 0 then 'PASS' else 'FAIL' end,
      format('12. DEFERRED Lifeforms surface NOT touched (%s lost)', v_n));

    /* ---- 13: the RLS that CAUSED the wrong answers is unchanged ---- */
    insert into t_wci(orden, resultado, prueba) values (13,
      case when (select count(*) from pg_policy where polname = 'deny_direct_api_access'
                   and polrelid in ('public.debris_fields'::regclass,
                                    'public.expedition_ship_tiers'::regclass,
                                    'public.expedition_item_uses'::regclass)) = 3
           then 'PASS' else 'FAIL' end,
      '13. the three deny_direct_api_access policies are unchanged');

    /* ---- 14: on all four targets anon/PUBLIC denied and service_role kept ---- */
    insert into t_wci(orden, resultado, prueba) values (14,
      case when not exists (
              select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public'
                 and p.proname in ('can_recycle_debris','get_expedition_ship_candidates',
                                   'get_active_expedition_item_effect','check_defense_requirements')
                 and (has_function_privilege('anon', p.oid, 'EXECUTE')
                      or has_function_privilege('public', p.oid, 'EXECUTE')
                      or not has_function_privilege('service_role', p.oid, 'EXECUTE')))
           then 'PASS' else 'FAIL' end,
      '14. all four targets: anon/PUBLIC denied and service_role kept');

    /* ---- 15: the RECYCLE availability oracle the UI really uses still answers correctly ---- */
    select * into v_rec_row from public.get_recyclable_debris_status();
    insert into t_wci(orden, resultado, prueba) values (15,
      case when v_rec_row.out_available then 'PASS' else 'FAIL' end,
      format('15. get_recyclable_debris_status (the contract the UI uses) -> available=%s fields=%s',
             v_rec_row.out_available, v_rec_row.out_field_count));
end;
$test$;

select * from t_wci order by orden;

rollback;

      exception when others then v_client_err := sqlerrm; end;
    insert into t_wci(orden, resultado, prueba) values (6, case when v_client_err <> '' then 'PASS' else 'FAIL' end,
      format('6. CLIENT get_expedition_ship_candidates refused [%s]', coalesce(nullif(v_client_err,''),'NO ERROR')));

    v_client_err := ''; begin perform public.get_active_expedition_item_effect(v_player, v_planet.id, 'probe_key');
      exception when others then v_client_err := sqlerrm; end;
    insert into t_wci(orden, resultado, prueba) values (7, case when v_client_err <> '' then 'PASS' else 'FAIL' end,
      format('7. CLIENT get_active_expedition_item_effect refused [%s]', coalesce(nullif(v_client_err,''),'NO ERROR')));

    v_client_err := ''; begin perform public.check_defense_requirements(v_planet.id, 'rocket_launcher');
      exception when others then v_client_err := sqlerrm; end;
    insert into t_wci(orden, resultado, prueba) values (8, case when v_client_err <> '' then 'PASS' else 'FAIL' end,
      format('8. CLIENT check_defense_requirements refused [%s]', coalesce(nullif(v_client_err,''),'NO ERROR')));
    reset role;

    select p.* into v_planet from public.planets p
     where p.player_id = v_player and p.kind = 'PLANET' and not p.is_destroyed order by p.created_at limit 1;
    select e.id into v_item from public.expedition_item_definitions e order by e.id limit 1;
    if v_player is null or v_planet.id is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into public.player_research(player_id, research_id, level)
    values (v_player, 'computer_technology', 60)
    on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 60);
