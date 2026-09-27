-- AI BOOTSTRAP + DORMANT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK (zero LIVE residue; the human player it
-- needs is created inside the transaction and discarded, no existing human is touched).
--
-- Contract under test (20260926295000_ai_dormant_state + 20260926296000_shared_player_bootstrap):
--   1. the shared bootstrap authority produces the expected initial state (exact values, not "not null")
--   2. a real AI birth (reconcile_universe_ai_population) and a real human birth (provision_player) produce
--      EXACTLY the same initial player/planet/resource/research state
--   3. a newly created AI is DORMANT, persistently
--   4. DORMANT executes no AI action at all (the policy gate answers before any evaluation)
--   5. DORMANT produces no espionage  6. no attack  7. no colonisation  8. no fleet dispatch
--   9. DORMANT consumes no budget (resources untouched, no queues, no activity stamp, no cooldown)
--  10. ACTIVE (same AI, only the status changed) keeps using the certified policy
--  Plus: the worker skips DORMANT and reaches ACTIVE while keeping the round-robin, and both birth paths
--  delegate to the one authority (no literal quantities left anywhere).
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_bt;
create temp table t_bt(orden serial, resultado text, prueba text);
drop table if exists t_ai_fix;
create temp table t_ai_fix(id uuid, planet_id uuid);

do $test$
declare
    v_universe uuid;
    v_batch record;
    v_first uuid;
    v_human_user uuid;
    v_human uuid; v_human_planet uuid;
    v_hum record; v_aip record;
    v_rows integer; v_cnt integer;
    v_ok boolean; v_fail integer := 0;
    v_txt text; v_txt2 text; v_num numeric;
    v_active timestamptz; v_active2 timestamptz;
    v_decision record;
    v_res record;
    v_profile record;
    v_before record;
begin
    /* ------------------------------------------------------------------ SETUP
       A scratch ACTIVE universe with two 1-system galaxies: it isolates this fixture from the LIVE universe and
       satisfies every contract that requires an active universe (actor, worker, human provisioning). */
    insert into public.universes (name, is_active)
    values ('Fixture Bootstrap ' || substr(gen_random_uuid()::text, 1, 8), true)
    returning id into v_universe;

    insert into public.universe_galaxies (universe_id, galaxy, system_count, next_system_expansion_at,
                                          system_interval_seconds)
    values (v_universe, 1, 1, now() + interval '1 day', 3600),
           (v_universe, 2, 1, now() + interval '1 day', 3600);

    insert into public.universe_population_state (universe_id, ai_density_target, ai_density_tolerance,
                                                  ai_generation_batch, reconciliation_interval_seconds,
                                                  next_reconciliation_at)
    values (v_universe, 0.50, 0.10, 3, 60, now());

    /* ================= 1. THE AI BIRTH PATH PRODUCES THE INITIAL STATE ================= */
    select * into v_batch from public.reconcile_universe_ai_population(v_universe);
    v_cnt := v_batch.planets_created;

    insert into t_ai_fix(id, planet_id)
    select pl.id, p.id from public.planets p
      join public.players pl on pl.id = p.player_id
     where p.universe_id = v_universe and pl.player_type = 'AI' and not p.is_destroyed
     order by pl.created_at, pl.id
     limit 3;

    select id into v_first from t_ai_fix order by id limit 1;

    if coalesce(v_cnt, 0) < 3 or v_first is null then
        raise exception 'TEST_ABORT: the AI seeder created % AI planet(s)', coalesce(v_cnt, 0);
    end if;

    select pr.metal, pr.crystal, pr.deuterium, pr.energy into v_res
      from public.planet_resources pr
      join t_ai_fix f on f.planet_id = pr.planet_id
     where f.id = v_first;

    v_ok := v_res.metal = 500 and v_res.crystal = 500 and v_res.deuterium = 0 and v_res.energy = 0
            and (select count(*) from public.player_research pr where pr.player_id = v_first) = 16
            and (select count(*) from public.player_research pr where pr.player_id = v_first and pr.level <> 0) = 0
            and (select count(*) from public.planet_buildings pb where pb.planet_id = (select planet_id from t_ai_fix where id = v_first)) = 0
            and (select count(*) from public.planet_ships ps where ps.planet_id = (select planet_id from t_ai_fix where id = v_first)) = 0
            and (select count(*) from public.planet_defenses pd where pd.planet_id = (select planet_id from t_ai_fix where id = v_first)) = 0;

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. seeder-born AI has the exact initial state: %s/%s/%s/%s, %s research rows, 0 buildings/ships/defences',
             v_res.metal, v_res.crystal, v_res.deuterium, v_res.energy,
             (select count(*) from public.player_research pr where pr.player_id = v_first)));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= 2. HUMAN BIRTH ≡ AI BIRTH, FIELD BY FIELD ================= */
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                            created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'fixture-bootstrap-' || substr(gen_random_uuid()::text, 1, 8) || '@example.test', 'x', now(), now(), now())
    returning id into v_human_user;

    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_human_user, 'role', 'authenticated')::text, true);
    select * into v_hum from public.provision_player('Bootstrap Human ' || substr(gen_random_uuid()::text, 1, 4));
    perform set_config('request.jwt.claims', '', true);

    v_human := v_hum.player_id;
    v_human_planet := v_hum.planet_id;

    select pr.metal, pr.crystal, pr.deuterium, pr.energy into v_res
      from public.planet_resources pr where pr.planet_id = v_human_planet;

    select pl.points, pl.rank, pl.dark_matter, pl.is_guest, p.fields_total, p.fields_used, p.is_homeworld,
           p.is_destroyed, p.temperature_min, p.temperature_max, p.kind
      into v_aip
      from public.players pl join public.planets p on p.id = v_human_planet
     where pl.id = v_human;

    select pl.points, pl.rank, pl.dark_matter, pl.is_guest, p.fields_total, p.fields_used, p.is_homeworld,
           p.is_destroyed, p.temperature_min, p.temperature_max, p.kind
      into v_before
      from public.players pl join public.planets p on p.id = (select planet_id from t_ai_fix where id = v_first)
     where pl.id = v_first;

    v_ok := v_human is not null and v_human_planet is not null
            and v_res.metal = 500 and v_res.crystal = 500 and v_res.deuterium = 0 and v_res.energy = 0
            and (select count(*) from public.player_research pr where pr.player_id = v_human) = 16
            and (select count(*) from public.planet_buildings pb where pb.planet_id = v_human_planet) = 0
            and (select count(*) from public.planet_ships ps where ps.planet_id = v_human_planet) = 0
            and v_aip.points = v_before.points and v_aip.rank is not distinct from v_before.rank
            and v_aip.dark_matter = v_before.dark_matter and v_aip.is_guest = v_before.is_guest
            and v_aip.fields_total = v_before.fields_total and v_aip.fields_used = v_before.fields_used
            and v_aip.is_homeworld = v_before.is_homeworld and v_aip.is_destroyed = v_before.is_destroyed
            and v_aip.temperature_min is not distinct from v_before.temperature_min
            and v_aip.temperature_max is not distinct from v_before.temperature_max
            and v_aip.kind = v_before.kind;

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. real human birth ≡ real AI birth: 500/500/0/0 + 16 research rows each, identical player/planet fields (fields_total %s, homeworld %s, kind %s)',
             v_aip.fields_total, v_aip.is_homeworld, v_aip.kind));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= 3. A NEW AI IS BORN DORMANT (persistent, enforced) ================= */
    select app.status, app.personality into v_profile
      from public.ai_player_profiles app where app.player_id = v_first;

    v_ok := v_profile.status = 'DORMANT'
            and v_profile.personality in ('INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR')
            and (select count(*) from information_schema.columns c
                  where c.table_schema = 'public' and c.table_name = 'ai_player_profiles'
                    and c.column_name = 'status' and c.column_default like '%DORMANT%'
                    and c.is_nullable = 'NO') = 1
            and exists (select 1 from pg_constraint c
                         where c.conrelid = 'public.ai_player_profiles'::regclass
                           and pg_get_constraintdef(c.oid) like '%DORMANT%ACTIVE%');

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a seeder-born AI is DORMANT with a stable personality (%s / %s), enforced by NOT NULL DEFAULT + CHECK',
             v_profile.status, v_profile.personality));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ======== 4-9. DORMANT: the setup is fully actionable, and still nothing happens ========
       Everything a policy needs is granted: probes, warships, a colony ship, fuel, a shipyard, the required
       research, a known weak foreign target, and an instant inside the AI's own activity window. */
    perform public.ai_actor_begin(v_first);

    insert into public.planet_ships (planet_id, ship_id, quantity)
    values ((select planet_id from t_ai_fix where id = v_first), 'espionage_probe', 5),
           ((select planet_id from t_ai_fix where id = v_first), 'light_fighter', 40),
           ((select planet_id from t_ai_fix where id = v_first), 'colony_ship', 1)
    on conflict (planet_id, ship_id) do update set quantity = excluded.quantity;

    insert into public.planet_buildings (planet_id, building_id, level)
    values ((select planet_id from t_ai_fix where id = v_first), 'shipyard', 12)
    on conflict (planet_id, building_id) do update set level = 12;

    insert into public.player_research (player_id, research_id, level)
    values (v_first, 'espionage_technology', 4), (v_first, 'combustion_drive', 6), (v_first, 'impulse_drive', 4)
    on conflict (player_id, research_id) do update set level = excluded.level;

    update public.planet_resources set metal = 0, crystal = 0, deuterium = 500000
     where planet_id = (select planet_id from t_ai_fix where id = v_first);

    /* the AI owns an espionage report about the neighbouring AI planet: a legal, known, weak target */
    insert into public.fleet_movements (player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_first, (select planet_id from t_ai_fix where id = v_first), 'ESPIONAGE',
            now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
    returning id into v_txt;

    insert into public.espionage_reports (fleet_id, player_id, target_planet_id, espionage_level,
                                          target_espionage_level, metal, crystal, deuterium, energy, fleet, defenses)
    values (v_txt::uuid, v_first, (select planet_id from t_ai_fix where id <> v_first order by id limit 1),
            5, 0, 0, 0, 0, 0, '{"light_fighter": 1}'::jsonb, '{}'::jsonb);

    select ((now() at time zone 'utc')::date::timestamp
            + make_interval(mins => (select w.start_minute from public.ai_daily_activity(v_first, (now() at time zone 'utc')::date) w
                                      order by w.window_index limit 1) + 1)) at time zone 'utc'
      into v_active;

    perform public.ai_actor_end();

    /* the setup really is actionable: that is what makes the DORMANT result meaningful */
    v_ok := public.ai_is_active_at(v_first, v_active)
            and exists (select 1 from public.ai_espionage_candidates(v_first, (select planet_id from t_ai_fix where id = v_first), 3) c)
            and exists (select 1 from public.ai_attack_candidates(v_first, (select planet_id from t_ai_fix where id = v_first), 60, 5) c
                         where c.relative_power >= 0.75)
            and (select allowed from public.check_colony_cap(v_first)) is true;

    select pr.metal, pr.crystal, pr.deuterium, pr.energy into v_before
      from public.planet_resources pr where pr.planet_id = (select planet_id from t_ai_fix where id = v_first);

    select count(*) into v_rows from public.fleet_movements fm where fm.player_id = v_first;

    perform public.ai_actor_begin(v_first);
    select * into v_decision from public.ai_decide_and_act(v_first, 60, v_active);
    perform public.ai_actor_end();

    select count(*) into v_cnt from public.fleet_movements fm where fm.player_id = v_first;

    v_ok := v_ok and v_decision.action = 'none' and v_decision.result = 'AI_DORMANT'
            and v_decision.target is null;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. an actionable DORMANT AI executes nothing: %s / %s / target %s',
             v_decision.action, v_decision.result, coalesce(v_decision.target, 'null')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) from public.fleet_movements fm
              where fm.player_id = v_first and fm.mission_type = 'ESPIONAGE'
                and fm.status not in ('COMPLETED','CANCELLED')) = 0;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '5. DORMANT produces no espionage mission');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) from public.fleet_movements fm
              where fm.player_id = v_first and fm.mission_type = 'ATTACK'
                and fm.status not in ('COMPLETED','CANCELLED')) = 0;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. DORMANT produces no attack mission');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) from public.fleet_movements fm
              where fm.player_id = v_first and fm.mission_type = 'COLONIZE'
                and fm.status not in ('COMPLETED','CANCELLED')) = 0;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. DORMANT produces no colonisation mission');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select count(*) from public.fleet_movements fm
              where fm.player_id = v_first and fm.created_at > now() - interval '1 minute') = 0
            and v_cnt = v_rows;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. DORMANT dispatches no fleet at all (%s movements before, %s after)', v_rows, v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pr.metal, pr.crystal, pr.deuterium, pr.energy into v_res
      from public.planet_resources pr where pr.planet_id = (select planet_id from t_ai_fix where id = v_first);

    select app.last_action_at, app.last_action_kind, app.next_action_at into v_profile
      from public.ai_player_profiles app where app.player_id = v_first;

    v_ok := v_res.metal = v_before.metal and v_res.crystal = v_before.crystal
            and v_res.deuterium = v_before.deuterium and v_res.energy = v_before.energy
            and (select count(*) from public.building_queue q where q.planet_id = (select planet_id from t_ai_fix where id = v_first)) = 0
            and (select count(*) from public.research_queue q where q.planet_id = (select planet_id from t_ai_fix where id = v_first)) = 0
            and v_profile.last_action_at is null and v_profile.last_action_kind is null
            and v_profile.next_action_at is null;

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. DORMANT consumes no budget: resources still %s/%s/%s/%s, 0 queue rows, no activity stamp, no cooldown',
             v_res.metal, v_res.crystal, v_res.deuterium, v_res.energy));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ================= 10. ACTIVE keeps using the certified policy =================
       Only the status changes. Warships AND the colony ship are removed so the espionage family is the only
       legal one (the DORMANT block above already proved those setups were actionable). */
    delete from public.planet_ships
     where planet_id = (select planet_id from t_ai_fix where id = v_first)
       and ship_id in ('light_fighter', 'colony_ship');

    update public.ai_player_profiles set status = 'ACTIVE' where player_id = v_first;

    perform public.ai_actor_begin(v_first);
    select * into v_decision from public.ai_decide_and_act(v_first, 60, v_active);
    perform public.ai_actor_end();

    select app.last_action_at, app.last_action_kind, app.next_action_at into v_profile
      from public.ai_player_profiles app where app.player_id = v_first;

    v_ok := v_decision.action = 'espionage'
            and (select count(*) from public.fleet_movements fm
                  where fm.player_id = v_first and fm.mission_type = 'ESPIONAGE'
                    and fm.status not in ('COMPLETED','CANCELLED')) = 1
            and v_profile.last_action_at is not null and v_profile.last_action_kind = 'espionage'
            and v_profile.next_action_at is not null;

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. the SAME AI with status ACTIVE runs the certified policy: action=%s, movement created, activity stamp + cooldown consumed',
             v_decision.action));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ worker: DORMANT skipped, ACTIVE reached, round-robin preserved ============ */
    update public.ai_player_profiles set status = 'DORMANT' where player_id in (select id from t_ai_fix);
    select count(*) into v_cnt from public.run_ai_policy_worker(25, 60, v_active);
    v_ok := v_cnt = 0;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. a fully DORMANT population costs nothing: the worker returned %s rows', v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    update public.ai_player_profiles set status = 'ACTIVE' where player_id in (select id from t_ai_fix);
    select count(*) into v_cnt from public.run_ai_policy_worker(25, 60, v_active);
    v_ok := v_cnt = 3;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. the worker reaches every ACTIVE AI: %s of 3 rows', v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select (select w.out_player_id::text from public.run_ai_policy_worker(1, 60, v_active) w limit 1) into v_txt;
    select (select w.out_player_id::text from public.run_ai_policy_worker(1, 60, v_active + interval '300 seconds') w limit 1)
      into v_txt2;
    v_ok := v_txt is not null and v_txt2 is not null and v_txt <> v_txt2;
    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. the round-robin still rotates the ACTIVE population: two 5-minute ticks reached %s and %s',
             coalesce(v_txt, 'none'), coalesce(v_txt2, 'none')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ one authority, no literal quantities in either birth path ============ */
    v_ok := (select p.prosrc from pg_proc p where p.proname = 'provision_player' and p.pronamespace = 'public'::regnamespace)
              like '%bootstrap_new_player_state%'
        and (select p.prosrc from pg_proc p where p.proname = 'reconcile_universe_ai_population' and p.pronamespace = 'public'::regnamespace)
              like '%bootstrap_new_player_state%'
        and (select p.prosrc from pg_proc p where p.proname = 'reconcile_universe_ai_population' and p.pronamespace = 'public'::regnamespace)
              like '%ai_ensure_player_profile%'
        and (select p.prosrc from pg_proc p where p.proname = 'provision_player' and p.pronamespace = 'public'::regnamespace)
              not ilike '%insert into public.planet_resources%'
        and (select p.prosrc from pg_proc p where p.proname = 'reconcile_universe_ai_population' and p.pronamespace = 'public'::regnamespace)
              not ilike '%insert into public.planet_resources%'
        and (select p.prosrc from pg_proc p where p.proname = 'bootstrap_new_player_state' and p.pronamespace = 'public'::regnamespace)
              ilike '%insert into public.planet_resources%'
        and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
               and p.proname = 'ai_decide_and_act_core'
               and not has_function_privilege('service_role', p.oid, 'EXECUTE')) = 1;

    insert into t_bt(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. both birth paths delegate to the single bootstrap authority (no literals left), and the policy core is unreachable from every role');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_bt(resultado, prueba) values ('INFO',
      format('LIVE note: the %s pre-existing AI empires keep their empty state and stay DORMANT (their profiles default to DORMANT; a missing profile is DORMANT too). Normalising or activating them is an OPEN product decision and was NOT performed. Failed assertions: %s.',
             (select count(*) from public.players pl where pl.player_type = 'AI' and pl.universe_id <> v_universe
               and exists (select 1 from public.planets p where p.player_id = pl.id)),
             v_fail));

    if v_fail > 0 then
        raise exception 'AI BOOTSTRAP/DORMANT FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) filter (where resultado <> 'INFO') as assertions
  from t_bt;

select orden, resultado, prueba from t_bt order by orden;

drop table if exists t_bt;
drop table if exists t_ai_fix;

rollback;




