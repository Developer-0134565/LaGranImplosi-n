-- AI NORMALIZATION + BEGINNER PROTECTION FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK (zero LIVE residue; the social objects it
-- needs — a scratch universe, scratch AI empires and one human — are created inside the transaction).
--
-- Contract under test (20260926297000_ai_empire_normalization + 20260926298000_beginner_protection):
--   1. an AI empire in the legacy state (0/0/0/0, no research) is detected as a candidate and a dry run writes
--      nothing.
--   2. the backfill gives it EXACTLY the human initial state: 500/500/0/0 + 16 level-0 research rows.
--   3. it creates no buildings, ships or defences, and preserves identity/homeworld/personality.
--   4. it never activates: the empires stay DORMANT and the profile is created when missing.
--   5. it is idempotent: a second run reports 0 candidates and changes nothing.
--   6. it never overwrites progress: an empire with progress is skipped and counted.
--   7-14. beginner protection (human targets): the fresh human is protected until created_at + 24 h; the
--      frontier case; an ATTACK is refused with TARGET_BEGINNER_PROTECTED and creates no movement; the same
--      attack succeeds out of protection; ESPIONAGE is allowed; an AI target is out of the human rule's scope;
--      and the trigger only acts on mission_type = 'ATTACK'.
--
-- LIMITATION: single-session harness with ROLLBACK, like every fixture of this repository.

begin;

drop table if exists t_bp;
create temp table t_bp(orden serial, resultado text, prueba text);

do $test$
declare
    v_universe uuid;
    v_a1 uuid; v_a2 uuid; v_a3 uuid;
    v_p1 uuid; v_p2 uuid; v_p3 uuid;
    v_human_user uuid; v_hum record; v_human uuid; v_human_planet uuid;
    v_res record; v_before record; v_norm record; v_prot record;
    v_rows integer; v_cnt integer; v_ok boolean; v_fail integer := 0;
    v_raised text;
begin
    /* ------------------------------------------------------------------ SETUP
       A scratch ACTIVE universe so the normalisation is scoped and no LIVE empire is touched. */
    insert into public.universes (name, is_active)
    values ('Fixture Normalization ' || substr(gen_random_uuid()::text, 1, 8), true)
    returning id into v_universe;

    insert into public.universe_galaxies (universe_id, galaxy, system_count, next_system_expansion_at,
                                          system_interval_seconds)
    values (v_universe, 1, 1, now() + interval '1 day', 3600),
           (v_universe, 2, 1, now() + interval '1 day', 3600);

    /* three legacy-state AI empires: A1 without profile, A2 with a DORMANT profile, A3 for the progress case */
    insert into public.players (universe_id, user_id, username, points, rank, dark_matter, is_guest, player_type)
    values (v_universe, null, 'FixtureAI-A1', 0, null, 0, false, 'AI') returning id into v_a1;
    insert into public.players (universe_id, user_id, username, points, rank, dark_matter, is_guest, player_type)
    values (v_universe, null, 'FixtureAI-A2', 0, null, 0, false, 'AI') returning id into v_a2;
    insert into public.players (universe_id, user_id, username, points, rank, dark_matter, is_guest, player_type)
    values (v_universe, null, 'FixtureAI-A3', 0, null, 0, false, 'AI') returning id into v_a3;

    insert into public.planets (universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
                                is_homeworld, is_destroyed)
    values (v_universe, v_a1, 'FixtureAI-A1 world', 1, 1, 1, 163, 0, true, false) returning id into v_p1;
    insert into public.planets (universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
                                is_homeworld, is_destroyed)
    values (v_universe, v_a2, 'FixtureAI-A2 world', 1, 1, 2, 163, 0, true, false) returning id into v_p2;
    insert into public.planets (universe_id, player_id, name, galaxy, system, position, fields_total, fields_used,
                                is_homeworld, is_destroyed)
    values (v_universe, v_a3, 'FixtureAI-A3 world', 1, 1, 3, 163, 0, true, false) returning id into v_p3;

    /* the legacy initial state, exactly as the old seeder wrote it */
    insert into public.planet_resources (planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_p1, 0, 0, 0, 0, now(), now()),
           (v_p2, 0, 0, 0, 0, now(), now()),
           (v_p3, 0, 0, 0, 0, now(), now());

    insert into public.ai_player_profiles (player_id, personality, status) values (v_a2, 'SCIENTIST', 'DORMANT');

    /* ============ 1. CANDIDATE DETECTION + DRY RUN WRITES NOTHING ============ */
    select * into v_norm from public.normalize_existing_ai_empires(v_universe, null, true);
    select pr.metal, pr.crystal, (select count(*) from public.player_research r where r.player_id = v_a1) as research
      into v_before
      from public.planet_resources pr where pr.planet_id = v_p1;

    v_ok := v_norm.out_candidates = 3 and v_norm.out_normalized = 0
            and v_before.metal = 0 and v_before.crystal = 0 and v_before.research = 0;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. dry run detects %s legacy candidates and writes nothing (still %s/%s, %s research rows)',
             v_norm.out_candidates, v_before.metal, v_before.crystal, v_before.research));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 2. THE BACKFILL GIVES THE HUMAN INITIAL STATE ============ */
    select * into v_norm from public.normalize_existing_ai_empires(v_universe, null, false);

    select pr.metal, pr.crystal, pr.deuterium, pr.energy into v_res
      from public.planet_resources pr where pr.planet_id = v_p1;

    v_ok := v_norm.out_candidates = 3 and v_norm.out_normalized = 3
            and v_res.metal = 500 and v_res.crystal = 500 and v_res.deuterium = 0 and v_res.energy = 0
            and (select count(*) from public.player_research r where r.player_id = v_a1) = 16
            and (select count(*) from public.player_research r where r.player_id = v_a3) = 16
            and (select count(*) from public.player_research r where r.player_id = v_a1 and r.level <> 0) = 0;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. backfill normalised %s empires: %s/%s/%s/%s + 16 level-0 research rows each',
             v_norm.out_normalized, v_res.metal, v_res.crystal, v_res.deuterium, v_res.energy));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 3. NO INVENTORY + IDENTITY/HOMEWORLD/PERSONALITY PRESERVED ============ */
    v_ok := (select count(*) from public.planet_buildings b where b.planet_id in (v_p1, v_p2, v_p3)) = 0
            and (select count(*) from public.planet_ships s where s.planet_id in (v_p1, v_p2, v_p3)) = 0
            and (select count(*) from public.planet_defenses d where d.planet_id in (v_p1, v_p2, v_p3)) = 0
            and (select count(*) from public.players pl where pl.id in (v_a1, v_a2, v_a3)
                   and pl.username in ('FixtureAI-A1','FixtureAI-A2','FixtureAI-A3')
                   and pl.user_id is null and pl.player_type = 'AI') = 3
            and (select count(*) from public.planets p where p.id = v_p1
                   and p.player_id = v_a1 and p.galaxy = 1 and p.system = 1 and p.position = 1
                   and p.is_homeworld and not p.is_destroyed) = 1
            and (select a.personality from public.ai_player_profiles a where a.player_id = v_a2) = 'SCIENTIST';
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '3. no buildings/ships/defences created; identity, homeworld coordinates and personality preserved');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 4. NEVER ACTIVATES: DORMANT, PROFILE CREATED WHEN MISSING ============ */
    v_ok := (select a.status from public.ai_player_profiles a where a.player_id = v_a1) = 'DORMANT'
            and (select a.status from public.ai_player_profiles a where a.player_id = v_a2) = 'DORMANT'
            and (select a.status from public.ai_player_profiles a where a.player_id = v_a3) = 'DORMANT'
            and (select count(*) from public.ai_player_profiles where status = 'ACTIVE') = 0;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. the normalised empires are DORMANT (profile created when missing) and no profile anywhere is ACTIVE');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 5. IDEMPOTENT ============ */
    select * into v_norm from public.normalize_existing_ai_empires(v_universe, null, false);
    v_ok := v_norm.out_candidates = 0 and v_norm.out_normalized = 0 and v_norm.out_already_ok = 3
            and (select pr.metal from public.planet_resources pr where pr.planet_id = v_p1) = 500
            and (select count(*) from public.player_research r where r.player_id = v_a1) = 16;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. idempotent: rerun reports candidates=%s normalised=%s already_ok=%s and changes nothing',
             v_norm.out_candidates, v_norm.out_normalized, v_norm.out_already_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 6. NEVER OVERWRITES PROGRESS ============ */
    update public.planet_resources set metal = 1234 where planet_id = v_p3;
    insert into public.planet_buildings (planet_id, building_id, level) values (v_p3, 'metal_mine', 5);

    select * into v_norm from public.normalize_existing_ai_empires(v_universe, null, false);
    v_ok := v_norm.out_candidates = 0 and v_norm.out_normalized = 0 and v_norm.out_skipped_with_progress = 1
            and (select pr.metal from public.planet_resources pr where pr.planet_id = v_p3) = 1234
            and (select b.level from public.planet_buildings b where b.planet_id = v_p3 and b.building_id = 'metal_mine') = 5;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. progress is never overwritten: skipped_with_progress=%s, its 1234 metal and level-5 mine intact',
             v_norm.out_skipped_with_progress));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 7. A FRESHLY PROVISIONED HUMAN IS PROTECTED ============ */
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                            created_at, updated_at)
    values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'fixture-bp-' || substr(gen_random_uuid()::text, 1, 8) || '@example.test', 'x', now(), now(), now())
    returning id into v_human_user;

    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_human_user, 'role', 'authenticated')::text, true);
    select * into v_hum from public.provision_player('Fixture Human BP ' || substr(gen_random_uuid()::text, 1, 4));
    perform set_config('request.jwt.claims', '', true);

    v_human := v_hum.player_id;
    v_human_planet := v_hum.planet_id;

    select * into v_prot from public.get_player_attack_protection(v_human);
    v_ok := v_prot.out_protected is true and v_prot.out_reason = 'BEGINNER_PROTECTION_24H'
            and v_prot.out_protected_until =
                (select pl.created_at + interval '24 hours' from public.players pl where pl.id = v_human)
            and (select pl.user_id from public.players pl where pl.id = v_human) is not null;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. a freshly provisioned human is protected (%s, until %s = created_at + 24 h)',
             v_prot.out_reason, v_prot.out_protected_until));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 8. FRONTIER CASE ============ */
    v_ok := (select out_protected from public.get_player_attack_protection(v_human,
                 (select pl.created_at + interval '24 hours' - interval '1 second'
                    from public.players pl where pl.id = v_human))) is true
            and (select out_protected from public.get_player_attack_protection(v_human,
                 (select pl.created_at + interval '24 hours' from public.players pl where pl.id = v_human))) is false;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. frontier: protected one second before expiry, released exactly at created_at + 24 h');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 9. AN ATTACK AGAINST THE PROTECTED HUMAN IS REFUSED ============
       Attacker: the scratch AI A1, armed exactly as a real attack requires (ships, research, fuel, free slot). */
    perform public.ai_actor_begin(v_a1);
    insert into public.planet_ships (planet_id, ship_id, quantity)
    values (v_p1, 'light_fighter', 10), (v_p1, 'espionage_probe', 3)
    on conflict (planet_id, ship_id) do update set quantity = excluded.quantity;
    insert into public.planet_buildings (planet_id, building_id, level) values (v_p1, 'shipyard', 3)
      on conflict (planet_id, building_id) do update set level = 3;
    insert into public.player_research (player_id, research_id, level)
    values (v_a1, 'combustion_drive', 1), (v_a1, 'espionage_technology', 2)
    on conflict (player_id, research_id) do update set level = excluded.level;
    update public.planet_resources set deuterium = 500000 where planet_id = v_p1;

    v_raised := null;
    begin
        perform public.start_fleet_mixed(v_a1, v_p1, v_human_planet, '{"light_fighter": 1}'::jsonb, 'ATTACK');
    exception when others then v_raised := sqlerrm; end;

    select count(*) into v_cnt from public.fleet_movements fm
     where fm.player_id = v_a1 and fm.mission_type = 'ATTACK' and fm.destination_planet_id = v_human_planet;
    perform public.ai_actor_end();

    v_ok := v_raised like 'TARGET_BEGINNER_PROTECTED%' and v_cnt = 0;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. the attack against the protected human is refused (%s) and no movement was created',
             coalesce(left(v_raised, 60), 'accepted')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 10. ESPIONAGE AGAINST THE PROTECTED HUMAN IS ALLOWED ============ */
    perform public.ai_actor_begin(v_a1);
    v_raised := null;
    begin
        perform public.start_fleet_mixed(v_a1, v_p1, v_human_planet, '{"espionage_probe": 1}'::jsonb, 'ESPIONAGE');
    exception when others then v_raised := sqlerrm; end;
    select count(*) into v_cnt from public.fleet_movements fm
     where fm.player_id = v_a1 and fm.mission_type = 'ESPIONAGE' and fm.destination_planet_id = v_human_planet
       and fm.status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    v_ok := v_raised is null and v_cnt = 1;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. espionage against the protected human is ALLOWED (%s, %s movement) — the rule only guards attacks',
             coalesce(v_raised, 'no error'), v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 11. OUT OF PROTECTION THE SAME ATTACK SUCCEEDS ============ */
    update public.fleet_movements set status = 'COMPLETED'
     where player_id = v_a1 and status not in ('COMPLETED','CANCELLED');
    update public.players set created_at = now() - interval '3 days' where id = v_human;

    perform public.ai_actor_begin(v_a1);
    v_raised := null;
    begin
        perform public.start_fleet_mixed(v_a1, v_p1, v_human_planet, '{"light_fighter": 1}'::jsonb, 'ATTACK');
    exception when others then v_raised := sqlerrm; end;
    select count(*) into v_cnt from public.fleet_movements fm
     where fm.player_id = v_a1 and fm.mission_type = 'ATTACK' and fm.destination_planet_id = v_human_planet
       and fm.status not in ('COMPLETED','CANCELLED');
    perform public.ai_actor_end();

    v_ok := v_raised is null and v_cnt = 1;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. once out of protection the same attack is a normal attack (%s, %s movement)',
             coalesce(v_raised, 'no error'), v_cnt));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 12. AI TARGETS ARE OUT OF THE HUMAN RULE'S SCOPE ============ */
    v_ok := (select out_protected from public.get_player_attack_protection(v_a2)) is false
            and (select out_reason from public.get_player_attack_protection(v_a2)) = 'NOT_HUMAN_TARGET';
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. an AI empire is NOT covered by the human beginner rule (declared scope: AI already has its own attacker-side 24 h gate)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 13. TRIGGER COVERAGE AND SCOPE ============ */
    v_ok := exists (select 1 from pg_trigger t
                     where t.tgrelid = 'public.fleet_movements'::regclass
                       and t.tgname = 'trg_enforce_beginner_protection' and not t.tgisinternal)
            and (select p.prosrc from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname = 'enforce_beginner_protection_before_insert') like '%mission_type <> ''ATTACK''%'
            and not exists (select 1 from pg_proc p
                             where p.pronamespace = 'public'::regnamespace
                               and p.proname in ('start_support_fleet','start_colonize_fleet','start_fleet')
                               and p.prosrc like '%beginner_protection%');
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '13. the guard is a BEFORE INSERT trigger on fleet_movements acting only on ATTACK missions, so espionage, transport, colonisation and ACS defend are untouched');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 14. NO ACTIVATION + ACL ============ */
    v_ok := (select count(*) from public.ai_player_profiles where status = 'ACTIVE') = 0
            and (select count(*) from public.ai_player_profiles
                  where player_id in (v_a1, v_a2, v_a3) and status = 'DORMANT') = 3
            and has_function_privilege('service_role', 'public.normalize_existing_ai_empires(uuid,integer,boolean)', 'EXECUTE')
            and has_function_privilege('service_role', 'public.get_player_attack_protection(uuid,timestamp with time zone)', 'EXECUTE')
            and not has_function_privilege('authenticated', 'public.normalize_existing_ai_empires(uuid,integer,boolean)', 'EXECUTE')
            and not has_function_privilege('anon', 'public.get_player_attack_protection(uuid,timestamp with time zone)', 'EXECUTE');
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. no AI profile is ACTIVE (all three normalised empires are DORMANT) and both new authorities are service_role only');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 15. EVERY NEWBORN AI IS BORN WITH THE BASE STATE ============ */
    v_ok := not exists (
        select 1 from public.players pl
        join public.planets h on h.player_id = pl.id and h.is_homeworld and not h.is_destroyed and h.kind = 'PLANET'
        left join public.planet_resources pr on pr.planet_id = h.id
        where pl.player_type = 'AI' and pl.created_at > now() - interval '24 hours'
          and (pr.metal is distinct from 500 or pr.crystal is distinct from 500 or pr.deuterium is distinct from 0
               or pr.energy is distinct from 0
               or (select count(*) from public.player_research r where r.player_id = pl.id) <> 16
               or exists (select 1 from public.player_research r where r.player_id = pl.id and r.level <> 0)
               or (select a.status from public.ai_player_profiles a where a.player_id = pl.id) is distinct from 'DORMANT'));
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('15. every AI empire born in the last 24 h is in the base state (%s newborn(s) checked; the AI gate blocks any action during those 24 h, so none of them can have progressed)',
             (select count(*) from public.players where player_type = 'AI' and created_at > now() - interval '24 hours')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ============ 16. THE SINGLE AI BIRTH PATH CANNOT CARRY A QUANTITY LITERAL ============ */
    v_ok := (select not (p.prosrc ilike '%metal%' or p.prosrc ilike '%crystal%' or p.prosrc ilike '%deuterium%')
                    and not (p.prosrc ilike '%insert into public.planet_resources%'
                             or p.prosrc ilike '%insert into planet_resources%')
                    and p.prosrc ilike '%bootstrap_new_player_state%'
                    and p.prosrc ilike '%ai_ensure_player_profile%'
               from pg_proc p where p.pronamespace = 'public'::regnamespace
                 and p.proname = 'reconcile_universe_ai_population')
            and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                  and p.prosrc ilike '%insert into public.players%') = 2;
    insert into t_bp(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '16. the seeder body has no metal/crystal/deuterium word, never inserts planet_resources, delegates to bootstrap_new_player_state + ai_ensure_player_profile, and only TWO functions in the schema insert players (provision_player and the seeder)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_bp(resultado, prueba) values ('INFO', format('failed assertions: %s', v_fail));

    if v_fail > 0 then
        raise exception 'AI NORMALIZATION/BEGINNER PROTECTION FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) filter (where resultado = 'PASS') as passed,
       count(*) filter (where resultado <> 'INFO') as assertions
  from t_bp;

select orden, resultado, prueba from t_bp order by orden;

drop table if exists t_bp;

rollback;
