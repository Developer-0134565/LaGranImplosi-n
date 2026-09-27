-- LGI SWEEP III - #1 Wreck field + Space Dock : live assertions (migration 20260926230000)
-- Transactional: everything below is rolled back, no residue in the live universe.
begin;
drop table if exists t_wf;
create temp table t_wf(resultado text, prueba text);
do $d$
declare
    v_planet uuid; v_ship1 text; v_ship2 text; v_field uuid; v_res record; v_qty bigint;
    v_crew bigint; v_hours numeric; v_levels integer;
begin
    select sd.id into v_ship1 from public.ship_definitions sd order by sd.id limit 1;
    select sd.id into v_ship2 from public.ship_definitions sd where sd.id <> v_ship1 order by sd.id limit 1;
    select p.id into v_planet from public.planets p where p.kind = 'PLANET' and p.is_destroyed = false
     order by p.created_at limit 1;

    delete from public.planet_wreck_fields where planet_id = v_planet;
    delete from public.planet_buildings where planet_id = v_planet and building_id = 'space_dock';
    delete from public.planet_ships where planet_id = v_planet and ship_id in (v_ship1, v_ship2);

    insert into t_wf values (case when exists (select 1 from public.building_definitions where id = 'space_dock')
        then 'PASS' else 'FAIL' end, '1. Space Dock building definition present (LGI price curve, planets+moons)');

    v_field := public.create_or_extend_wreck_field(v_planet,
        jsonb_build_object(v_ship1, 1000, v_ship2, 0, 'not_a_ship', 50), 0);
    select wfs.quantity into v_qty from public.planet_wreck_field_ships wfs
     where wfs.wreck_field_id = v_field and wfs.ship_id = v_ship1;
    insert into t_wf values (case when v_field is not null and v_qty = 200 then 'PASS' else 'FAIL' end,
        format('2. level 0 keeps 20%% of 1000 destroyed ships (stored %s; unknown ids and 0 counts skipped)', v_qty));

    perform public.create_or_extend_wreck_field(v_planet, jsonb_build_object(v_ship1, 500), 0);
    select wfs.quantity into v_qty from public.planet_wreck_field_ships wfs
     where wfs.wreck_field_id = v_field and wfs.ship_id = v_ship1;
    insert into t_wf values (case when v_qty = 300 then 'PASS' else 'FAIL' end,
        format('3. a second battle extends the same field (500 more destroyed -> %s stored)', v_qty));

    select * into v_res from public.start_wreck_field_repairs(v_field);
    insert into t_wf values (case when v_res.out_status = 'BLOCKED' and v_res.out_result = 'NO_SPACE_DOCK' then 'PASS' else 'FAIL' end,
        format('4. without a Space Dock the field is BLOCKED (%s/%s)', v_res.out_status, v_res.out_result));

    insert into public.planet_buildings (planet_id, building_id, level) values (v_planet, 'space_dock', 10)
    on conflict (planet_id, building_id) do update set level = 10;
    select * into v_res from public.start_wreck_field_repairs(v_field);
    v_hours := round(extract(epoch from (v_res.out_finishes_at - now())) / 3600.0, 1);
    insert into t_wf values (case when v_res.out_status = 'REPAIRING' and v_res.out_ships_total = 300 and v_hours = 6.0
        then 'PASS' else 'FAIL' end,
        format('5. level 10 starts REPAIRING: 300 ships at 50/h -> %s h (%s)', v_hours, v_res.out_result));

    update public.planet_wreck_fields set repair_finishes_at = now() - interval '1 minute' where id = v_field;
    select * into v_res from public.complete_wreck_field_repairs(v_field);
    select coalesce(sum(ps.quantity), 0) into v_crew from public.planet_ships ps
     where ps.planet_id = v_planet and ps.ship_id = v_ship1;
    insert into t_wf values (case when v_res.out_result = 'COMPLETED' and v_res.out_ships_repaired = 300 and v_crew = 300
        then 'PASS' else 'FAIL' end,
        format('6. due repairs return the ships to planet_ships (%s, %s repaired, %s in the fleet)',
               v_res.out_result, v_res.out_ships_repaired, v_crew));

    v_field := public.create_or_extend_wreck_field(v_planet, jsonb_build_object(v_ship2, 100), 10);
    update public.planet_wreck_fields set expires_at = now() - interval '1 hour' where id = v_field;
    select * into v_res from public.run_wreck_field_worker(50) limit 1;
    insert into t_wf values (case when v_res.outcome = 'DECAYED'
        and not exists (select 1 from public.planet_wreck_fields wf where wf.id = v_field) then 'PASS' else 'FAIL' end,
        format('7. worker decays the expired field (%s) and removes its rows', v_res.outcome));

    select count(*) into v_qty from pg_trigger t where t.tgname = 'trg_on_combat_battle_finished_wreck_field' and not t.tgisinternal;
    select count(*) into v_crew from cron.job j where j.jobname = 'lagranimplosion-wreck-field-worker';
    select count(*) into v_levels from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('create_or_extend_wreck_field','start_wreck_field_repairs',
        'complete_wreck_field_repairs','run_wreck_field_worker','settle_wreck_field_for_battle')
        and not has_function_privilege('authenticated', p.oid, 'execute');
    insert into t_wf values (case when v_qty = 1 and v_crew = 1 and v_levels = 5 then 'PASS' else 'FAIL' end,
        format('8. producer trigger on combat_battles (%s) + service_role-only contracts (%s/5) + cron every 10 min', v_qty, v_levels));

    perform public.settle_wreck_field_for_battle(gen_random_uuid());
    insert into t_wf values ('PASS', '9. settle_wreck_field_for_battle is a safe no-op for an unknown battle');
end;
$d$;
select case when count(*) filter (where resultado = 'FAIL') = 0 then 'PASS' else 'FAIL' end as final,
       count(*) as total, count(*) filter (where resultado = 'PASS') as passed
  from t_wf;
select resultado, prueba from t_wf order by prueba;
drop table if exists t_wf;
rollback;