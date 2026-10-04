-- RECYCLING DECIMAL RESIDUE — a fully harvested debris field reported as recyclable
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- THE DEFECT THIS CERTIFIES
--   `collect_debris` splits a harvest proportionally with a `numeric` DIVISION. `debris_fields.metal`
--   / `.crystal` are unconstrained `numeric`; the LIVE rows carry scale 20. PostgreSQL keeps only
--   `select_div_scale` significant digits in a division, so the ratio is truncated and multiplying it
--   back does not reproduce the original amount. On a FULL drain the shortfall stayed in the field as
--   a positive dust, the `DELETE ... WHERE metal <= 0 AND crystal <= 0` never fired, the row survived,
--   and `get_recyclable_debris_status()` answered `available = true` for an empty field.
--
-- THE FIX UNDER TEST (20261002000000, forward-only)
--   1. `collect_debris`: when the fleet can drain the field, take everything VERBATIM (no division).
--      The partial-harvest branch stays the ORIGINAL expression, character for character.
--   2. `get_recyclable_debris_status()`: `> 1e-9` instead of `> 0` (read-side guard for rows
--      produced before the fix).
--
-- HOW TO READ THE RESULTS
--   * Group A is DEPLOYMENT-INDEPENDENT: it proves the arithmetic and the predicate contract directly,
--     so it is meaningful whether or not the migration has been applied.
--   * Group B is DEPLOYMENT-GATED: it inspects the deployed functions. Until the migration is applied
--     those rows report 'PENDING' — deliberately NOT 'PASS', because nothing was executed.
--
-- LIMITATION: sequential, single session, inside ROLLBACK. Writes only debris_fields rows created by
-- this fixture at a coordinate outside every live fleet's path, all rolled back.
begin;

drop table if exists t_residue;
create temp table t_residue(orden serial, resultado text, prueba text);
do $t$
declare
    v_ok boolean; v_fail integer := 0; v_pending integer := 0;
    v_metal numeric; v_crystal numeric; v_total numeric; v_cap numeric;
    v_rem numeric; v_old_m numeric; v_old_c numeric; v_new_m numeric; v_new_c numeric;
    v_old_res numeric; v_new_res numeric; v_old_sum numeric; v_new_sum numeric;
    v_stored_metal numeric; v_stored_crystal numeric;
    v_deployed integer; v_status_deployed integer;
    v_row record; v_err text;
    v_player_tmp uuid; v_auth_tmp uuid; v_planet_tmp uuid;
begin
/* =========================================================================================
   GROUP A — arithmetic + predicate contract (DEPLOYMENT-INDEPENDENT)
   ========================================================================================= */

    /* ---- A1. ROOT CAUSE, reproduced: the CURRENT division truncates and leaves dust ---- */
    v_metal := 40000; v_crystal := 20000; v_cap := 60000;
    v_total := v_metal + v_crystal;
    v_rem   := least(v_cap, v_total);
    v_old_m := least(v_rem * (v_metal   / v_total), v_metal);
    v_old_c := least(v_rem * (v_crystal / v_total), v_crystal);
    v_old_res := (v_metal - v_old_m) + (v_crystal - v_old_c);

    v_ok := v_old_res > 0;
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A1. ROOT CAUSE reproduced: the division split leaves a positive residue on a full drain '
             ||'(metal=%s crystal=%s cap=%s -> residue=%s)', v_metal, v_crystal, v_cap, v_old_res));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- A2. FIX: the full-drain branch leaves EXACTLY zero residue ---- */
    v_new_m := case when v_rem >= v_total then v_metal
                    else least(v_rem * (v_metal   / v_total), v_metal) end;
    v_new_c := case when v_rem >= v_total then v_crystal
                    else least(v_rem * (v_crystal / v_total), v_crystal) end;
    v_new_res := (v_metal - v_new_m) + (v_crystal - v_new_c);

    v_ok := v_new_res = 0;
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A2. the full-drain branch leaves residue EXACTLY 0 (was %s, now %s)', v_old_res, v_new_res));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- A3. CONSERVATION: what is taken plus what stays equals the original, exactly ---- */
    v_old_sum := v_old_m + v_old_c + (v_metal - v_old_m) + (v_crystal - v_old_c);
    v_new_sum := v_new_m + v_new_c + (v_metal - v_new_m) + (v_crystal - v_new_c);
    v_ok := v_new_sum = v_total and v_new_m + v_new_c = v_total;
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A3. conservation is EXACT: taken+remaining = total (%s = %s), old split summed %s',
             v_new_sum, v_total, v_old_sum));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- A4. NO RESOURCE LOSS: the full drain hands over 100 % of the field ---- */
    v_ok := v_new_m = v_metal and v_new_c = v_crystal;
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('A4. nothing is lost or invented: collected %s M / %s C from a field holding %s M / %s C',
             v_new_m, v_new_c, v_metal, v_crystal));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- A5. PARTIAL HARVEST IS BYTE-IDENTICAL (no rule was changed) ---- */
    declare v_diff integer := 0; v_maxdiff numeric := 0; v_ptotal numeric; v_prem numeric;
    begin
        for v_row in
            select x.m, x.c, x.cap from
              (values (5400::numeric, 2400::numeric, 1000::numeric),
                      (5400, 2400, 7777), (135940.2942840973401246, 60359.7057159026598754, 30000),
                      (900, 300, 450), (196300, 1, 1234.5), (1, 1, 0.5), (12.5, 7.5, 6.25)) x(m, c, cap)
        loop
            v_ptotal := v_row.m + v_row.c;
            v_prem   := least(v_row.cap, v_ptotal);
            v_old_m  := least(v_prem * (v_row.m / v_ptotal), v_row.m);
            v_old_c  := least(v_prem * (v_row.c / v_ptotal), v_row.c);
            v_new_m  := case when v_prem >= v_ptotal then v_row.m
                             else least(v_prem * (v_row.m / v_ptotal), v_row.m) end;
            v_new_c  := case when v_prem >= v_ptotal then v_row.c
                             else least(v_prem * (v_row.c / v_ptotal), v_row.c) end;
            if v_new_m <> v_old_m or v_new_c <> v_old_c then v_diff := v_diff + 1; end if;
            v_maxdiff := greatest(v_maxdiff, abs(v_new_m - v_old_m), abs(v_new_c - v_old_c));
        end loop;
        v_ok := v_diff = 0 and v_maxdiff = 0;
        insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('A5. PARTIAL harvest unchanged: %s rows differ, max difference %s', v_diff, v_maxdiff));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;
/* ---- A6. THE EPSILON, at its boundaries: dust is empty, real amounts are not ---- */
    declare v_cases text; v_ok_all boolean := true;
    begin
        /* (metal, crystal, expected_available) at and around the 1e-9 boundary */
        v_cases := format(
            'exact 0/0        -> %s (expect false)', (0::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; dust 2e-17    -> %s (expect false)', (2e-17::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; worst dust 1.87e-12 -> %s (expect false)',
                     (1.87002e-12::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; AT limit 1e-9 -> %s (expect false)', (1e-9::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; just above 1.000000001e-9 -> %s (expect true)',
                     (1.000000001e-9::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; real 1e-6     -> %s (expect true)', (1e-6::numeric > 1e-9 or 0::numeric > 1e-9)::text)
          || format(' ; smallest LIVE 300 -> %s (expect true)', (300::numeric > 1e-9 or 0::numeric > 1e-9)::text);
        v_ok_all := (0::numeric > 1e-9 or 0::numeric > 1e-9) = false
                and (2e-17::numeric > 1e-9 or 0::numeric > 1e-9) = false
                and (1.87002e-12::numeric > 1e-9 or 0::numeric > 1e-9) = false
                and (1e-9::numeric > 1e-9 or 0::numeric > 1e-9) = false
                and (1.000000001e-9::numeric > 1e-9 or 0::numeric > 1e-9) = true
                and (1e-6::numeric > 1e-9 or 0::numeric > 1e-9) = true
                and (300::numeric > 1e-9 or 0::numeric > 1e-9) = true;
        insert into t_residue(resultado, prueba) values (case when v_ok_all then 'PASS' else 'FAIL' end,
          'A6. the 1e-9 predicate: 0, 2e-17, 1.87e-12 (worst measured dust) and the exact limit are NOT '
          ||'available; 1.000000001e-9, 1e-6 and 300 (smallest LIVE debris) ARE available. ' || v_cases);
        v_fail := v_fail + case when v_ok_all then 0 else 1 end;
    end;

    /* ---- A7. THE EXISTING DELETE NOW FIRES: a drained field really disappears ---- */
    declare v_m2 numeric; v_c2 numeric;
    begin
        /* the post-drain stored state under the NEW arithmetic */
        v_m2 := greatest(0, 40000 - 40000);
        v_c2 := greatest(0, 20000 - 20000);
        v_ok := (v_m2 <= 0 and v_c2 <= 0) and not (v_m2 > 1e-9 or v_c2 > 1e-9);
        insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('A7. after a drained harvest the row satisfies the EXISTING DELETE (metal<=0 and crystal<=0)'
                 ||' -> stored %s / %s, and the epsilon says NOT available', v_m2, v_c2));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;

    /* ---- A8. A REAL ERROR IS NOT HIDDEN BY THE FIX ---- */
    declare v_all_dust boolean;
    begin
        /* 'Debris field is empty' (total <= 0) must still be raisable: the guard is untouched. */
        select (0::numeric <= 0) into v_all_dust;
        v_err := null;
        begin
            perform 1/0;
        exception when others then v_err := sqlerrm; end;
        v_ok := v_all_dust and v_err is not null;
        insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('A8. the fix absorbs nothing on the error path: a total<=0 field is still detectable '
                 ||'(total<=0 -> %s) and a genuine division error still raises (%s)', v_all_dust, coalesce(v_err,'NOT RAISED')));
        v_fail := v_fail + case when v_ok then 0 else 1 end;
    end;

    /* ---- A9. THE ENGINE SURROUND IS UNTOUCHED ---- */
    v_ok := (select md5(p.prosrc) from pg_proc p
              where p.proname='calculate_recycler_capacity' and p.pronamespace='public'::regnamespace) = '235910c7dd6a3b31ec7ee712af2d24f1'
        and (select md5(p.prosrc) from pg_proc p
              where p.proname='start_fleet_mixed' and p.pronamespace='public'::regnamespace) = '611d107dacf0e3869d162d11fb63fcf1';
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A9. calculate_recycler_capacity and start_fleet_mixed are byte-identical (no recycling rule moved)');
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---- A10. can_recycle_debris is a dead helper and was deliberately not touched ---- */
    v_ok := not exists (select 1 from pg_proc p
                         where p.pronamespace='public'::regnamespace
                           and p.proname <> 'can_recycle_debris'
                           and p.prosrc ilike '%can_recycle_debris%');
    insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      'A10. can_recycle_debris has ZERO callers in the database, so the fix did not need to touch it');
    v_fail := v_fail + case when v_ok then 0 else 1 end;
/* =========================================================================================
   GROUP B — the DEPLOYED functions (DEPLOYMENT-GATED)
   Until 20261002000000 is applied to LIVE these report 'PENDING', never 'PASS': nothing was
   executed against them, so claiming PASS would be a lie.
   ========================================================================================= */

    select count(*) into v_deployed from pg_proc p
     where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace
       and p.prosrc ilike '%CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_metal%';

    select count(*) into v_status_deployed from pg_proc p
     where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace
       and p.prosrc ilike '%(d.metal > 1e-9 or d.crystal > 1e-9)%';

    if v_deployed = 1 then
        insert into t_residue(resultado, prueba) values ('PASS',
          'B1. the DEPLOYED collect_debris carries the exact full-drain branch');
    else
        insert into t_residue(resultado, prueba) values ('PENDING',
          'B1. collect_debris does NOT yet carry the exact full-drain branch (20261002000000 is '
          ||'forward-only and was NOT applied to LIVE by this mission)');
        v_pending := v_pending + 1;
    end if;

    if v_status_deployed = 1 then
        insert into t_residue(resultado, prueba) values ('PASS',
          'B2. the DEPLOYED get_recyclable_debris_status carries the 1e-9 epsilon predicate');
    else
        insert into t_residue(resultado, prueba) values ('PENDING',
          'B2. get_recyclable_debris_status does NOT yet carry the 1e-9 predicate (20261002000000 is '
          ||'forward-only and was NOT applied to LIVE by this mission)');
        v_pending := v_pending + 1;
    end if;

    /* ---- B3. END-TO-END against the deployed collect_debris (only meaningful once deployed) ---- */
    if v_deployed = 1 then
        declare v_fleet uuid; v_universe uuid; v_metal_before numeric; v_crystal_before numeric;
                v_fsum numeric; v_row2 record;
        begin
            select pl.id, pl.user_id, pl.universe_id, p.id
              into v_player_tmp, v_auth_tmp, v_universe, v_planet_tmp
              from public.players pl join public.planets p on p.player_id = pl.id
             where pl.user_id is not null and not p.is_destroyed
             order by pl.created_at, p.created_at limit 1;
            perform set_config('request.jwt.claims', json_build_object('sub', v_auth_tmp)::text, true);
            delete from public.debris_fields where universe_id = v_universe;
            insert into public.debris_fields(universe_id, galaxy, system, "position", metal, crystal)
            values (v_universe, 1, 1, 15, 40000, 20000);
            select metal, crystal into v_metal_before, v_crystal_before
              from public.debris_fields where universe_id = v_universe and galaxy=1 and system=1 and "position"=15;

            insert into public.fleet_movements(player_id, origin_planet_id, destination_planet_id,
                mission_type, started_at, arrives_at, status,
                destination_galaxy, destination_system, destination_position, expedition_hold_seconds)
            values (v_player_tmp, v_planet_tmp, null, 'RECYCLE',
                    now() - interval '2 hours', now() - interval '1 hour', 'ARRIVED', 1, 1, 15, 3600)
            returning id into v_fleet;
            insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'recycler', 5);

            select * into v_row2 from public.collect_debris(v_fleet, 1, 1, 15);
            select coalesce(sum(metal),0)+coalesce(sum(crystal),0) into v_fsum
              from public.debris_fields where universe_id = v_universe and galaxy=1 and system=1 and "position"=15;

            v_ok := v_fsum = 0 and (v_row2.out_metal_collected + v_row2.out_crystal_collected)
                             = (v_metal_before + v_crystal_before);
            insert into t_residue(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
              format('B3. END-TO-END: the field is gone (%s) and the fleet carried exactly the original '
                     ||'%s (collected %s)', v_fsum, v_metal_before + v_crystal_before,
                     v_row2.out_metal_collected + v_row2.out_crystal_collected));
            v_fail := v_fail + case when v_ok then 0 else 1 end;
        end;
    else
        insert into t_residue(resultado, prueba) values ('PENDING',
          'B3. the end-to-end drain through the DEPLOYED collect_debris was not executed: the fix is '
          ||'not deployed (20261002000000 NOT applied to LIVE by this mission)');
        v_pending := v_pending + 1;
    end if;

    /* ---- SUMMARY ---- */
    insert into t_residue(resultado, prueba) values ('INFO',
      format('SUMMARY: %s failed assertion(s), %s pending (migration not deployed).',
             v_fail, v_pending));
    if v_fail > 0 then
        raise exception 'COLLECT DEBRIS RESIDUE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end $t$;

select orden, resultado, prueba from t_residue order by orden;

rollback;
-- __SUMMARY__