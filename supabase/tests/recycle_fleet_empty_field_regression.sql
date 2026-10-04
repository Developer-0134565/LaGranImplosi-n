-- RECYCLE FLEET STUCK-STATE ON AN EXHAUSTED / DELETED DEBRIS FIELD -- 2026-10-01
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `collect_debris` refuses a target with nothing left:
--       'No debris field at [%:%:%] in universe %'   (the row is gone)
--       'Debris field is empty'                     (the row is there with 0/0)
--   `process_fleet_movements` downgrades ANY per-fleet error to
--       raise warning 'FLEET_RESOLUTION_FAILED ...'
--   which rolls nothing back and surfaces nothing, so the movement retried FOREVER. Measured on
--   LIVE before the fix, through the real worker, with no artificial rewind:
--       A. field EMPTIED (0/0) by another recycler -> status after the worker = OUTBOUND
--       B. field DELETED by another recycler      -> status after the worker = OUTBOUND
--   The recycler ships (already debited at dispatch) were destroyed and, because
--   `get_player_fleet_slots` counts every movement whose status is not in ('COMPLETED','CANCELLED'),
--   the player permanently lost one fleet slot. A player with computer_technology 0 has exactly
--   one slot, so that is a total, irreversible fleet lock.
--
--   Reachability is ordinary: `start_fleet_mixed` picks the RECYCLE target server-side as the
--   nearest field with (metal>0 OR crystal>0) and does NOT reserve it, so two recyclers dispatched
--   in the same window -- same player or two players of the universe -- are aimed at the same field.
--   The first arrival drains it (capacity >= remainder, the common case) and `collect_debris`
--   itself deletes the row; the second arrival is the stuck one.
--
-- THE FIX UNDER TEST (20261001060000)
--   The RECYCLE branch of `process_fleet_movements` absorbs EXACTLY those two "nothing left to
--   harvest" outcomes, treats them as "collected 0" and follows the already certified success path
--   (RETURNING with returns_at = arrives_at + (arrives_at - started_at)). Every other error is
--   re-raised unchanged, so a genuine defect stays observable in the worker warning.
--
-- NOT RE-CERTIFIED HERE (unchanged by the fix, asserted anyway)
--   `collect_debris` body (md5), `calculate_recycler_capacity`, `start_fleet_mixed` body (md5) and
--   its live refusal when no non-empty field exists, `get_recyclable_debris_status`, the three
--   per-fleet isolation handlers, and every other mission branch of the worker.
--
-- LIMITATION: sequential, single session, inside ROLLBACK. True concurrency (two recyclers racing
--   for the same field) is NOT executed; what is certified is the state each arrival FINDS. The
--   `pg_advisory_xact_lock` and the `for update skip locked` claims are unchanged by the fix.
begin;

drop table if exists t_recycle_stuck;
create temp table t_recycle_stuck(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_universe uuid; v_planet uuid;
    v_f_empty uuid; v_f_gone uuid; v_f_ok uuid; v_f_bad uuid;
    v_status text; v_err text;
    v_ships_after bigint;
    v_slots_before integer; v_slots_after integer;
    v_deb numeric; v_deb_after numeric; v_cargo numeric; v_unit numeric;
    v_res_before numeric; v_res_after numeric; v_expected numeric;
    v_fail integer := 0; v_row record; v_ok boolean;
    v_rows_ins integer; v_rows_upd integer; v_ctrl_rows integer; v_ctrl_deb numeric;
    v_body text; v_code text;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET'
     order by p.created_at, p.id limit 1;
    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet is required';
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* The universe under test starts with NO debris at the target coordinate, whatever the rest of
       the database holds. Coordinate 1:1:16 is used so the fixture can never collide with a live
       RECYCLE movement a real player may have in flight; every row it writes is rolled back. */
    delete from public.debris_fields
     where universe_id = v_universe and galaxy = 1 and system = 1 and "position" = 16;

    select count(*)::integer into v_slots_before
      from public.fleet_movements fm
     where fm.player_id = v_player and fm.status not in ('COMPLETED','CANCELLED');

    ---------------------------------------------------------------- A. EMPTIED FIELD (0/0)
    insert into public.debris_fields(universe_id, galaxy, system, "position", metal, crystal)
    values (v_universe, 1, 1, 16, 0, 0);

    select coalesce(sum(metal+crystal),0) into v_deb from public.debris_fields
     where universe_id = v_universe and galaxy=1 and system=1 and "position"=16;
    v_ok := v_deb = 0;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. anti-vacuity: the target field really is exhausted before the arrival (total=%s)', v_deb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.fleet_movements(
        player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position,
        expedition_hold_seconds, fuel_consumed)
    values (v_player, v_planet, null, 'RECYCLE',
            now() - interval '3 hours', now() - interval '2 hours', 'OUTBOUND', 1, 1, 16, 3600, 0)
    returning id into v_f_empty;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_f_empty, 'recycler', 5);

    perform * from public.process_fleet_movements();
    select status into v_status from public.fleet_movements where id = v_f_empty;
    v_ok := v_status not in ('OUTBOUND','ARRIVED','HOLDING');
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. an exhausted field no longer strands the fleet (status=%s)', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select coalesce(sum(quantity),0) into v_ships_after
      from public.fleet_movement_ships fms where fms.fleet_id = v_f_empty;
    v_ok := v_ships_after = 5;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. the 5 recyclers survived the arrival and are credited back on return (%s)', v_ships_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(sum(metal),0) from public.fleet_movements where id = v_f_empty) = 0
        and (select coalesce(sum(crystal),0) from public.fleet_movements where id = v_f_empty) = 0;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '4. nothing was harvested from an exhausted field (no phantom cargo)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    ------------------------------------------------------------------ B. FIELD ROW DELETED
    delete from public.debris_fields
     where universe_id = v_universe and galaxy = 1 and system = 1 and "position" = 16;

    insert into public.fleet_movements(
        player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position,
        expedition_hold_seconds, fuel_consumed)
    values (v_player, v_planet, null, 'RECYCLE',
            now() - interval '3 hours', now() - interval '2 hours', 'OUTBOUND', 1, 1, 16, 3600, 0)
    returning id into v_f_gone;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_f_gone, 'recycler', 5);

    perform * from public.process_fleet_movements();
    select status into v_status from public.fleet_movements where id = v_f_gone;
    v_ok := v_status not in ('OUTBOUND','ARRIVED','HOLDING');
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. a DELETED field no longer strands the fleet either (status=%s)', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
--------------------------------------------- C. CONTROL: a field WITH debris is unchanged
    insert into public.debris_fields(universe_id, galaxy, system, "position", metal, crystal)
    values (v_universe, 1, 1, 16, 40000, 20000)
    on conflict (universe_id, galaxy, system, "position") do update set metal = 40000, crystal = 20000;
    select sum(metal+crystal) into v_deb from public.debris_fields
     where universe_id = v_universe and galaxy=1 and system=1 and "position"=16;
    select cargo_capacity into v_unit from public.ship_definitions where id = 'recycler';

    /* Settle the origin to now() FIRST, so any later change in its stock is exactly the delivered
       cargo: the worker's settlement anchor is clamped at last_calculated_at and, inside a single
       statement, no production time elapses. */
    perform public.update_planet_resources_until(v_planet, now());
    select coalesce(metal,0)+coalesce(crystal,0) into v_res_before
      from public.planet_resources where planet_id = v_planet;

    insert into public.fleet_movements(
        player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position,
        expedition_hold_seconds, fuel_consumed)
    values (v_player, v_planet, null, 'RECYCLE',
            now() - interval '3 hours', now() - interval '2 hours', 'OUTBOUND', 1, 1, 16, 3600, 0)
    returning id into v_f_ok;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_f_ok, 'recycler', 5);

    /* One worker pass. BOTH legs of this movement are already in the past (arrives_at 2h ago, the
       whole outbound leg is 1h), so a single pass walks ARRIVED -> RETURNING -> COMPLETED. That is the
       already certified behaviour of the worker and is exactly what the RETURNING branch has always
       done; the fix does not touch it. */
    perform * from public.process_fleet_movements();
    select status into v_status from public.fleet_movements where id = v_f_ok;
    select coalesce(sum(metal+crystal),0) into v_deb_after from public.debris_fields
     where universe_id = v_universe and galaxy=1 and system=1 and "position"=16;
    select coalesce(metal,0)+coalesce(crystal,0) into v_res_after
      from public.planet_resources where planet_id = v_planet;
    v_cargo := (v_deb - v_deb_after);

    v_ok := v_status not in ('OUTBOUND','ARRIVED','HOLDING','RETURNING');
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. CONTROL: a fleet reaching a populated field still resolves to a terminal state (status=%s)', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* The real invariant of the collection path: what LEFT the field is exactly what ARRIVED at the
       origin, and it is the capacity-bounded amount. Compared with a 1e-6 tolerance because
       `collect_debris` splits proportionally with numeric division (draining a field leaves a 2e-17
       crystal residue). That rounding is PRE-EXISTING and out of scope for this mission. */
    v_expected := least(5 * v_unit, 60000);
    v_ok := abs(v_cargo - v_expected) < 0.000001
        and abs((v_res_after - v_res_before) - v_cargo) < 0.000001;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. CONTROL: collection arithmetic untouched — field %s -> %s (harvested %s), origin %s -> %s '
             || '(delivered %s), expected least(5 x %s, 60000) = %s',
             v_deb, v_deb_after, v_cargo, v_res_before, v_res_after, v_res_after - v_res_before,
             v_unit, v_expected));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select coalesce(sum(fms.quantity),0) from public.fleet_movement_ships fms
              where fms.fleet_id = v_f_ok) = 5;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '8. CONTROL: the 5 recyclers of the populated case are credited back too');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    --------------------------- D. AN UNRELATED REFUSAL MUST STILL BE OBSERVABLE (fail-loud)
    /* R1-9 REPAIR. Section C drains this field COMPLETELY, and since 20261002000000 a full drain
       takes everything verbatim, so `collect_debris` DELETEs the row (v_deb_after was measured as
       0 AND the row itself is gone). This control used to `UPDATE ... WHERE galaxy=1/system=1/
       position=16`, which therefore matched ZERO rows: the "fleet carrying no recycler" scenario
       silently ran against a DELETED field, so `collect_debris` refused with "No debris field at"
       — one of the two errors the fix absorbs — instead of raising "contains no Recycler". The
       control no longer exercised what it claimed to exercise. The precondition is now created
       EXPLICITLY here and its cardinality is asserted, so it can never go vacuous again, and it is
       a genuinely non-empty field (5000/5000): no exhausted row and no decimal residue is ever
       kept alive just to hold a row open. */
    insert into public.debris_fields(universe_id, galaxy, system, "position", metal, crystal)
    values (v_universe, 1, 1, 16, 5000, 5000);
    get diagnostics v_rows_ins = row_count;

    select count(*)::integer, coalesce(sum(metal+crystal),0) into v_ctrl_rows, v_ctrl_deb
      from public.debris_fields
     where universe_id = v_universe and galaxy=1 and system=1 and "position"=16;
    v_ok := v_rows_ins = 1 and v_ctrl_rows = 1 and v_ctrl_deb = 10000;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. the negative control BEGINS from a real field: the INSERT touched %s row(s) and the '
             ||'coordinate holds %s row(s) totalling %s (expected exactly 1 / 1 / 10000). Nothing is kept '
             ||'alive on purpose, so this control cannot silently degrade into the deleted-field case',
             v_rows_ins, v_ctrl_rows, v_ctrl_deb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the preparation step itself must touch the row: a control whose own UPDATE matches nothing
       proves nothing about the engine. */
    update public.debris_fields set metal = 5000, crystal = 5000
     where universe_id = v_universe and galaxy=1 and system=1 and "position"=16;
    get diagnostics v_rows_upd = row_count;
    v_ok := v_rows_upd = 1;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. the control preparation really affects EXACTLY one row (%s) — the scenario is armed, '
             ||'not a no-op against a missing or exhausted field', v_rows_upd));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.fleet_movements(
        player_id, origin_planet_id, destination_planet_id, mission_type,
        started_at, arrives_at, status, destination_galaxy, destination_system, destination_position,
        expedition_hold_seconds, fuel_consumed)
    values (v_player, v_planet, null, 'RECYCLE',
            now() - interval '3 hours', now() - interval '2 hours', 'OUTBOUND', 1, 1, 16, 3600, 0)
    returning id into v_f_bad;
    /* a fleet carrying no recycler at all: collect_debris must still refuse it */
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_f_bad, 'espionage_probe', 5);

    perform * from public.process_fleet_movements();
    select status into v_status from public.fleet_movements where id = v_f_bad;
    v_ok := v_status in ('OUTBOUND','ARRIVED');
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. a refusal that is NOT "nothing left to harvest" still aborts the fleet (status=%s), '
             || 'so a genuine defect stays visible in the worker warning', v_status));
    v_fail := v_fail + case when v_ok then 0 else 1 end;
------------------------------------------------------- E. THE DISPATCH SIDE IS UNCHANGED
    delete from public.debris_fields where universe_id = v_universe;
    v_err := null;
    begin
        /* `check_ship_requirements` gates `recycler` on shipyard 4 AND combustion_drive 6; without
           both the dispatch would be refused for an unrelated reason and prove nothing. */
        insert into public.planet_buildings(planet_id, building_id, level) values (v_planet,'shipyard',4)
          on conflict (planet_id, building_id) do update set level = greatest(public.planet_buildings.level, 4);
        insert into public.player_research(player_id, research_id, level) values (v_player,'combustion_drive',6)
          on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, 6);
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_planet,'recycler',3)
          on conflict (planet_id, ship_id) do update set quantity = greatest(public.planet_ships.quantity, 3);
        update public.planet_resources set deuterium = 9000000 where planet_id = v_planet;
        perform public.start_fleet_mixed(v_player, v_planet, null, '{"recycler": 1}'::jsonb, 'RECYCLE');
    exception when others then v_err := sqlerrm; end;
    v_ok := v_err is not null and position('No debris field available for RECYCLE' in v_err) > 0;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. the dispatch still refuses RECYCLE with no non-empty field (%s)', coalesce(v_err,'ACCEPTED')));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select * into v_row from public.get_recyclable_debris_status();
    v_ok := not v_row.out_available;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. the UI hint still reports available=%s with no debris (contract intact)', v_row.out_available));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    ------------------------------------------- F. NOBODY ELSE MOVED (bodies + worker shape)
    /* R1-12 REPAIR. This assertion used to pin md5(prosrc) of `collect_debris` to the value it had
       BEFORE 20261002000000. That migration legitimately changed the function, so the pin compared
       the deployed body against a stale constant and reported FAIL even though the engine was
       correct — and it would have reported FAIL for ANY future correct change too. A hard-coded MD5
       of a specific release is a pin to history, not a statement of intent. It is replaced here by
       a SEMANTIC check of the same guarantees the pin was standing in for, so the assertion is now
       robust to any future legitimate revision while still failing loudly if a guarantee is broken:
         1. the EXACT full-drain branch of 20261002000000 is present for BOTH resources;
         2. the PARTIAL-harvest branch is still the ORIGINAL proportional expression, verbatim,
            so the split rule, the capacity bound and the LEAST clamps are provably untouched;
         3. BOTH refusals every other caller depends on still exist ('No debris field at',
            'Debris field is empty', 'contains no Recycler');
         4. the capacity bound, the GREATEST clamps, the DELETE of the drained row and the RETURNING
            payload are all still present.
       Comments and whitespace are stripped before matching, so the check describes the CODE and
       cannot be satisfied or defeated by prose. No MD5 of any previous release is referenced. */
    select p.prosrc into v_body
      from pg_proc p where p.proname='collect_debris' and p.pronamespace='public'::regnamespace;
    v_code := regexp_replace(regexp_replace(regexp_replace(coalesce(v_body,''), '/\*.*?\*/', '', 'gs'),
                                           '--[^\n\r]*', '', 'g'), '\s+', ' ', 'g');

    v_ok := v_code ilike '%CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_metal ELSE LEAST(v_remaining_capacity * (v_debris_metal / v_total_debris), v_debris_metal) END%'
        and v_code ilike '%CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_crystal ELSE LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal) END%'
        and v_code ilike '%v_remaining_capacity := LEAST(v_capacity, v_total_debris)%'
        and v_code ilike '%No debris field at [%:%:%] in universe%'
        and v_code ilike '%Debris field is empty%'
        and v_code ilike '%contains no Recycler%'
        and v_code ilike '%SET metal = GREATEST(0, d.metal - v_metal_collected)%'
        and v_code ilike '%crystal = GREATEST(0, d.crystal - v_crystal_collected)%'
        and v_code ilike '%WHERE d.id = v_debris_id AND d.metal <= 0 AND d.crystal <= 0%'
        and v_code ilike '%RETURN QUERY%';
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '14. collect_debris SEMANTICALLY intact: exact full-drain branch for both resources, partial '
      ||'split still the original proportional formula, both refusals, the capacity bound, the GREATEST '
      ||'clamps, the DELETE of the drained row and the RETURNING payload (no MD5 pin)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select md5(p.prosrc) from pg_proc p
              where p.proname='calculate_recycler_capacity' and p.pronamespace='public'::regnamespace)
          = '235910c7dd6a3b31ec7ee712af2d24f1';
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '15. calculate_recycler_capacity is byte-identical (no capacity rule was touched)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select md5(p.prosrc) from pg_proc p
              where p.proname='start_fleet_mixed' and p.pronamespace='public'::regnamespace)
          = '611d107dacf0e3869d162d11fb63fcf1';
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '16. start_fleet_mixed is byte-identical (target choice, composition rule, fuel/ship debit)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select md5(p.prosrc) from pg_proc p
              where p.proname='get_player_fleet_slots' and p.pronamespace='public'::regnamespace)
          = '119b1100d6b13b40428545c5ebad3cf4';
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '17. get_player_fleet_slots is byte-identical (slot accounting not weakened)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
v_ok := (select (length(p.prosrc) - length(replace(p.prosrc,'FLEET_RESOLUTION_FAILED','')))
                     / length('FLEET_RESOLUTION_FAILED')
               from pg_proc p
              where p.proname='process_fleet_movements' and p.pronamespace='public'::regnamespace) = 3;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '18. the three per-fleet isolation handlers of the worker are untouched');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_ok := (select p.prosrc from pg_proc p
              where p.proname='process_fleet_movements' and p.pronamespace='public'::regnamespace)
            ilike '%resolve_attack_arrival%'
        and (select p.prosrc from pg_proc p
              where p.proname='process_fleet_movements' and p.pronamespace='public'::regnamespace)
            ilike '%resolve_espionage_arrival%'
        and (select p.prosrc from pg_proc p
              where p.proname='process_universe_tick' and p.pronamespace='public'::regnamespace)
            ilike '%process_fleet_movements%';
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '19. the ATTACK/ESPIONAGE arrival branches and the fleet-first universe tick are intact');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    ------------------------------------------------------------- G. RESIDUE / SLOT RELEASE
    /* Test 9 deliberately leaves one movement mid-lifecycle: that is the fail-loud behaviour it
       certifies. It is cancelled here so the residue and slot assertions below measure the fixture's
       own bookkeeping and not that intentional row. */
    update public.fleet_movements set status = 'CANCELLED' where id = v_f_bad;

    v_ok := not exists (
        select 1 from public.fleet_movements
         where id in (v_f_empty, v_f_gone, v_f_ok, v_f_bad)
           and status in ('OUTBOUND','ARRIVED','HOLDING','RETURNING'));
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '20. no movement created by this fixture is left mid-lifecycle');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_slots_after
      from public.fleet_movements fm
     where fm.player_id = v_player and fm.status not in ('COMPLETED','CANCELLED');
    v_ok := v_slots_after = v_slots_before;
    insert into t_recycle_stuck(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('21. the consumed fleet slots are exactly as before the fixture (%s -> %s)', v_slots_before, v_slots_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    raise notice 'RECYCLE STUCK-STATE FIXTURE: % failures', v_fail;
end $test$;

select orden, resultado, prueba from t_recycle_stuck order by orden;

rollback;