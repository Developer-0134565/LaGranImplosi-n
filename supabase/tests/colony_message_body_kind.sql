-- COLONY MESSAGE BODY-KIND FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- Contract under test (20260929000000): `notify_colony_established()` must produce a message for a
-- COLONY and must NOT produce one for a MOON.
--
-- Gap closed 2026-09-29 (Messaging residual cycle): the trigger is `AFTER INSERT ON public.planets`
-- and its only guard was `player_id is null or is_homeworld`. `settle_moon_creation_for_battle`
-- inserts the moon with the defender's player_id, is_homeworld = false and kind = 'MOON', so it
-- passed the guard: the defender received the correct 'Moon formed' message PLUS a false
-- 'Colony established' one claiming a colony ship founded the moon.
--
-- The fixture drives the REAL trigger with REAL inserts (no trigger disabled, nothing mocked):
--   1. a MOON insert produces NO 'Colony established'   <- the regression assertion
--   2. a COLONY insert still produces exactly one, with the real body and dedupe key
--   3. the moon row is a real MOON child of the defended planet
--   4. a homeworld address never carries a colony message
--   5. NO colony message may address a non-PLANET body (this is the whole invariant)
--   6. create_player_message keeps its ACL
--   7. the producer keeps SECURITY DEFINER + pinned search_path
--   8. the trigger is still attached after the migration
--   9. the moon producer still announces the moon itself
--  10. the pre-existing environment carried no false message (defect was latent, not active)
--
-- LIMITATION: single-session harness with ROLLBACK; concurrency not executed. The moon row is
-- created by the fixture (LIVE has 0 moons), so what is asserted is the CONTRACT's discrimination,
-- not the environment's data.

begin;

drop table if exists t_cmb;
create temp table t_cmb(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_planet record; v_home uuid;
    v_moon uuid; v_colony uuid; v_slot record;
    v_ok boolean; v_fails integer := 0; v_n integer; v_subj text; v_body text;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.* into v_planet
      from public.planets p where p.player_id = v_player and p.kind = 'PLANET' and not p.is_destroyed
     order by p.is_homeworld desc, p.created_at limit 1;
    if v_player is null or v_planet.id is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    select p.id into v_home
      from public.planets p where p.player_id = v_player and p.is_homeworld and not p.is_destroyed
     order by p.created_at limit 1;

    /* a genuinely free coordinate: LIVE's first systems are saturated (15/15), so the search spans
       the real galaxy/system space and picks the first genuinely free slot rather than a hard-coded
       coordinate that would be a latent collision against the unique (universe,galaxy,system,position). */
    select g.galaxy, s.system, p.position into v_slot
      from generate_series(1, 9) g(galaxy) cross join generate_series(1, 499) s(system)
      cross join generate_series(1, 15) p(position)
     where not exists (select 1 from public.planets px
                        where px.universe_id = v_universe and px.galaxy = g.galaxy
                          and px.system = s.system and px.position = p.position)
     order by g.galaxy, s.system, p.position limit 1;
    if v_slot.position is null then
        raise exception 'TEST_ABORT: the universe has no free coordinate';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------- 1. THE REGRESSION: a MOON insert must NOT produce a colony message ---------- */
    /* same shape as settle_moon_creation_for_battle: defender's player_id, is_homeworld = false,
       kind = 'MOON', parent = the defended planet, same coordinates. enforce_planet_kind_consistency
       is therefore exercised too, so the insert is only legal if the fixture is faithful. */
    insert into public.planets(universe_id, player_id, name, galaxy, system, position,
        fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    values (v_universe, v_player, 'Moon', v_planet.galaxy, v_planet.system, v_planet.position,
        1, 0, false, false, 'MOON', v_planet.id, 8500)
    returning id into v_moon;

    select count(*) into v_n from public.player_messages
     where recipient_player_id = v_player and dedupe_key = 'colony:' || v_moon::text;
    v_ok := v_n = 0;

    /* ---------- 2. a COLONY insert still produces exactly one, verbatim ---------- */
    insert into public.planets(universe_id, player_id, name, galaxy, system, position,
        fields_total, fields_used, is_homeworld, is_destroyed, kind)
    values (v_universe, v_player, 'ColonyOfTheFixture', v_slot.galaxy, v_slot.system, v_slot.position,
        1, 0, false, false, 'PLANET')
    returning id into v_colony;

    select subject, body into v_subj, v_body from public.player_messages
     where dedupe_key = 'colony:' || v_colony::text;
    v_ok := v_subj = 'Colony established'
            and v_body ilike '%ColonyOfTheFixture%'
            and v_body ilike 'Your colony ship founded%';
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. colony insert still produces one verbatim message: %s / %s', coalesce(v_subj,'(none)'), coalesce(v_body,'(none)')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 3. the moon row is a real MOON child of the defended planet ---------- */
    select count(*) into v_n from public.planets
     where id = v_moon and kind = 'MOON' and parent_planet_id = v_planet.id and not is_homeworld;
    v_ok := v_n = 1;
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the moon row is a real MOON child of the defended planet (rows=%s)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 4. a homeworld address never carries a colony message ---------- */
    select count(*) into v_n from public.player_messages
     where dedupe_key = 'colony:' || v_home::text;
    v_ok := v_n = 0;
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. colony messages addressed to a homeworld = %s (expected 0)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 5. THE WHOLE INVARIANT: no colony message may address a non-PLANET body ---------- */
    select count(*) into v_n
      from public.player_messages pm
      join public.planets p on p.id::text = split_part(pm.dedupe_key, ':', 2)

    /* ---------- 6. the only write path keeps its ACL ---------- */
    v_ok := not has_function_privilege('anon','public.create_player_message(uuid,uuid,text,text,text)','EXECUTE')
            and not has_function_privilege('authenticated','public.create_player_message(uuid,uuid,text,text,text)','EXECUTE')
            and has_function_privilege('service_role','public.create_player_message(uuid,uuid,text,text,text)','EXECUTE');
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '6. create_player_message ACL: anon=f authenticated=f service_role=t');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 7. the producer keeps its security shape ---------- */
    select (p.prosecdef and p.proconfig::text ilike '%search_path%') into v_ok
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'notify_colony_established';
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. producer stays SECURITY DEFINER with a pinned search_path (%s)', v_ok));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 8. the trigger is still attached (fix in the body, not a removed trigger) ---------- */
    select count(*) into v_n from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where c.relname = 'planets' and t.tgname = 'trg_notify_colony_established' and not t.tgisinternal;
    v_ok := v_n = 1;
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. trg_notify_colony_established still attached (count=%s)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 9. the moon producer still announces the moon itself ---------- */
    select (p.prosrc::text ilike '%Moon formed%') into v_ok
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'settle_moon_creation_for_battle';
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. settle_moon_creation_for_battle still announces the moon (%s)', v_ok));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* ---------- 10. the environment carried no false message before the fix ---------- */
    v_ok := not exists (
        select 1 from public.player_messages pm
          join public.planets p on p.id::text = split_part(pm.dedupe_key, ':', 2)
         where pm.dedupe_key like 'colony:%' and p.kind <> 'PLANET');
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '10. no pre-existing false colony message in the environment (defect was latent)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    raise notice 'COLONY_MESSAGE_BODY_KIND: % assertion(s) failed', v_fails;
end;
$test$;

select * from t_cmb order by orden;

rollback;

     where pm.dedupe_key like 'colony:%' and p.kind <> 'PLANET';
    v_ok := v_n = 0;
    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. colony messages addressing a non-PLANET body = %s (expected 0)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_cmb(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. moon insert -> colony messages = %s (expected 0)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
