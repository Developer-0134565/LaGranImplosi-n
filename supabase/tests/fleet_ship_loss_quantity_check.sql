-- FLEET SHIP-LOSS / CHECK REGRESSION FIXTURE — LA GRAN IMPLOSIÓN
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
-- Covers the class fixed by 20260928121226_fix_fleet_movement_ship_loss_quantity_check.sql:
--   no settlement path may leave `fleet_movement_ships.quantity = 0` (CHECK quantity > 0), and a rolled loss that
--   exhausts a whole stack must REMOVE the stack instead of aborting the statement.
--   1) moon destruction, "the moon survived AND every Deathstar was lost" — previously swallowed by the function's own
--      exception handler (no attempt row, no messages, Deathstars kept). Record: README_MOON_ENGINE.md §12.1 (D6).
--   2) expedition black hole consuming a whole stack — previously raised
--      `new row for relation "fleet_movement_ships" violates check constraint "fleet_movement_ships_quantity_chk"`,
--      which propagated through resolve_expedition_arrival. Record: README_FLEET_ENGINE.md.
-- LIMITATION: single-session harness; the rolls are deterministic but must be searched (bumped timestamps), so the
-- fixture finds a favourable instant instead of faking randomness.

begin;

drop table if exists t_flc;
create temp table t_flc(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_auth uuid; v_universe uuid; v_origin uuid; v_ai uuid;
    v_galaxy int; v_k int; v_i int; v_ai_planet uuid; v_moon uuid; v_fleet uuid; v_battle uuid;
    v_roll int; v_rip int; v_n int; v_err text; v_att record; v_ds bigint; v_zero int; v_msgs int;
    v_ok boolean; v_destroyed boolean; v_rows int; v_ok_runs int; v_bad_runs int; v_lost_total numeric;
    v_surv_total numeric; v_lost jsonb; v_surv jsonb; v_lp numeric;
    v_found boolean; v_outcome text; v_tries int; v_m1 int; v_m2 int; v_surv_before numeric;
begin
    select pl.id, pl.user_id, pl.universe_id into v_player, v_auth, v_universe
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;
    select p.id into v_origin from public.planets p
     where p.player_id = v_player and not p.is_destroyed and p.kind = 'PLANET' order by p.created_at limit 1;
    select pl.id into v_ai from public.players pl
     where pl.player_type = 'AI' and pl.id <> v_player order by pl.created_at limit 1;

    if v_player is null or v_origin is null or v_ai is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and an AI player are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    insert into public.player_research(player_id, research_id, level) values (v_player, 'computer_technology', 40)
    on conflict (player_id, research_id) do update set level = 40;
    delete from public.fleet_movements where player_id = v_player;
    delete from public.planets where parent_planet_id = v_origin;

    v_galaxy := coalesce((select max(p.galaxy) from public.planets p), 1);

    /* ================================ 1) MOON DESTRUCTION ================================ */
    v_ai_planet := null;
    for v_k in 0..19 loop
        begin
            insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
                temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind)
            values (v_universe, v_ai, 'FlcTarget', v_galaxy, 600 + v_k, 1, -20, 20, 10, 0, false, false, 'PLANET')
            returning id into v_ai_planet;
            exit;
        exception when unique_violation then
            v_ai_planet := null;
        end;
    end loop;

    if v_ai_planet is null then
        raise exception 'TEST_ABORT: no free coordinate for the foreign target';
    end if;

    insert into public.planets(universe_id, player_id, name, galaxy, system, position, temperature_min,
        temperature_max, fields_total, fields_used, is_homeworld, is_destroyed, kind, parent_planet_id, moon_diameter_km)
    select v_universe, v_ai, 'FlcMoon', p.galaxy, p.system, p.position, -20, 20, 10, 0, false, false,
           'MOON', p.id, 5000
      from public.planets p where p.id = v_ai_planet
    returning id into v_moon;

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at, updated_at)
    values (v_moon, 0, 0, 0, 0, clock_timestamp(), clock_timestamp()) on conflict (planet_id) do nothing;

    /* One attacker Deathstar against a 5 000 km moon: destruction chance = floor((100 - sqrt(5000)) * sqrt(1)) = 29,
       loss chance per Deathstar = floor(sqrt(5000) / 2) = 35. The regression instant is "the moon SURVIVED and the
       single Deathstar was lost" (roll > 29 and rip roll <= 35), which is exactly the case the legacy UPDATE could not
       represent. The rolls are deterministic in (fleet_id, started_at, arrives_at), so the harness searches a
       favourable dispatch timestamp instead of faking randomness. */
    v_found := false;
    v_tries := 0;
    v_ok_runs := 0;
    v_bad_runs := 0;
    v_err := null;

    for v_k in 1..60 loop
        insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
        values (v_player, v_origin, 'MOON_DESTRUCTION', clock_timestamp(), clock_timestamp() + interval '2 hours', 'ARRIVED')
        returning id into v_fleet;
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'deathstar', 1);
        insert into public.combat_battles(fleet_id, attacker_player_id, defender_planet_id, finished_at)
        values (v_fleet, v_player, v_moon, clock_timestamp())
        returning id into v_battle;
        v_tries := v_tries + 1;

        v_roll := floor(public.fleet_event_random(v_fleet, 'moon_destruction') * 100) + 1;
        v_rip := floor(public.fleet_event_random(v_fleet, 'moon_destruction_rip', 1) * 100) + 1;

        exit when v_roll > 29 and v_rip <= 35;

        delete from public.fleet_movement_ships where fleet_id = v_fleet;
        delete from public.combat_battles where id = v_battle;
        delete from public.fleet_movements where id = v_fleet;
    end loop;

    v_found := v_roll > 29 and v_rip <= 35;

    v_ok := v_found;
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. found the regression instant (moon survived + Deathstar lost) in %s attempt(s): roll %s > 29, rip %s <= 35',
             v_tries, v_roll, v_rip));
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    if v_found then
        v_err := null;
        begin
            v_outcome := public.settle_moon_destruction_for_battle(v_battle);
        exception when others then
            v_err := sqlerrm;
        end;

        select coalesce(sum(quantity), 0) into v_ds
          from public.fleet_movement_ships where fleet_id = v_fleet and ship_id = 'deathstar';
        select * into v_att from public.moon_destruction_attempts a where a.battle_id = v_battle;
        select not m.is_destroyed into v_ok from public.planets m where m.id = v_moon;
        v_msgs := case when v_ok then 1 else 0 end;
        select count(*) into v_m1 from public.player_messages pm
         where pm.dedupe_key in ('moon_destruction:' || v_battle::text, 'moon_destruction_attacker:' || v_battle::text);
        select count(*) into v_zero from public.fleet_movement_ships where fleet_id = v_fleet and quantity <= 0;

        /* 2. the settlement COMPLETES: outcome SURVIVED, provenance row, Deathstar really lost, moon still alive */
        v_ok := v_err is null and v_outcome = 'SURVIVED' and v_att.battle_id is not null
                and v_att.destroyed = false and v_att.deathstars_lost = 1 and v_att.deathstars = 1
                and v_msgs = 1 and v_m1 = 2;
        insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('2. moon survived: outcome %s, attempt row %s, lost %s/%s Deathstars, moon alive %s, messages %s%s',
                 coalesce(v_outcome, 'null'), coalesce(v_att.battle_id::text, 'MISSING'),
                 coalesce(v_att.deathstars_lost::text, '-'), coalesce(v_att.deathstars::text, '-'),
                 v_msgs, v_m1, coalesce(' [' || v_err || ']', '')));
        v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
        v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

        /* 3. the exhausted stack is REMOVED, not left at quantity = 0 (the CHECK that used to abort the statement) */
        v_ok := v_ds = 0 and v_zero = 0;
        insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('3. exhausted Deathstar stack removed: quantity total %s, rows with quantity <= 0: %s', v_ds, v_zero));
        v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
        v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

        /* 4. idempotency: replaying the same battle changes nothing (unique per battle) */
        perform public.settle_moon_destruction_for_battle(v_battle);
        select count(*) into v_rows from public.moon_destruction_attempts a where a.battle_id = v_battle;
        select coalesce(sum(quantity), 0) into v_ds
          from public.fleet_movement_ships where fleet_id = v_fleet and ship_id = 'deathstar';
        v_ok := v_rows = 1 and v_ds = 0;
        insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
          format('4. replay is idempotent: %s attempt row(s) after a second settlement, Deathstars left: %s', v_rows, v_ds));
        v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
        v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;
    else
        insert into t_flc(resultado, prueba) values ('FAIL',
          '1. the regression instant was not reachable in 60 deterministic attempts (roll/rip never satisfied)');
        v_bad_runs := v_bad_runs + 1;
    end if;

    /* ================================ 2) EXPEDITION BLACK HOLE ================================ */
    /* Legacy case (6/6 reproductions LIVE) with the fleet {espionage_probe 1, light_fighter 1}: total 2 -> the loss
       target is capped at total-1 = 1, the single-unit stack is therefore fully consumed, and the legacy
       `UPDATE ... quantity = quantity - 1` wrote quantity = 0 -> violated fleet_movement_ships_quantity_chk and the
       expedition could not resolve. */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, started_at, arrives_at, status)
    values (v_player, v_origin, 'EXPEDITION', clock_timestamp(), clock_timestamp() + interval '2 hours', 'ARRIVED')
    returning id into v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values
        (v_fleet, 'espionage_probe', 1), (v_fleet, 'light_fighter', 1);

    v_err := null;
    begin
        select bh.lost_ships, bh.surviving_ships, bh.loss_percentage into v_lost, v_surv, v_lp
          from public.resolve_expedition_black_hole(v_fleet) bh;
    exception when others then
        v_err := sqlerrm;
    end;

    select count(*) into v_zero from public.fleet_movement_ships where fleet_id = v_fleet and quantity <= 0;
    select coalesce(sum(quantity), 0) into v_rows from public.fleet_movement_ships where fleet_id = v_fleet;

    /* 5. the black hole RESOLVES (the error no longer propagates through resolve_expedition_arrival) */
    v_ok := v_err is null and v_lost is not null and v_surv is not null and v_lp = 50;
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. black hole resolves: lost %s, surviving %s, loss %s%%%s',
             coalesce(v_lost::text, 'null'), coalesce(v_surv::text, 'null'),
             coalesce(v_lp::text, '-'), coalesce(' [' || v_err || ']', '')));
    v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    /* 6. the fully consumed stack is REMOVED, the survivor is kept, and nothing is left at quantity = 0 */
    v_ok := v_zero = 0 and v_rows = 1
            and v_lost ? 'espionage_probe' and v_lost -> 'espionage_probe' = to_jsonb(1)
            and v_surv ? 'light_fighter' and v_surv -> 'light_fighter' = to_jsonb(1);
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. exhausted stack removed and survivor kept: %s unit(s) left, rows with quantity <= 0: %s', v_rows, v_zero));
    v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    /* 7. a mixed stack (partial loss) still subtracts instead of deleting, and never leaves quantity = 0 */
    delete from public.fleet_movement_ships where fleet_id = v_fleet;
    insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values
        (v_fleet, 'light_fighter', 3), (v_fleet, 'espionage_probe', 1);

    v_err := null;
    v_lost := null;
    begin
        select bh.lost_ships, bh.surviving_ships into v_lost, v_surv
          from public.resolve_expedition_black_hole(v_fleet) bh;
    exception when others then
        v_err := sqlerrm;
    end;

    select count(*) into v_zero from public.fleet_movement_ships where fleet_id = v_fleet and quantity <= 0;
    select coalesce(sum(quantity), 0) into v_surv_before
      from public.fleet_movement_ships where fleet_id = v_fleet;
    select coalesce(sum(value::bigint), 0) into v_lost_total
      from jsonb_each_text(coalesce(v_lost, '{}'::jsonb));

    v_ok := v_err is null and v_zero = 0
            and v_surv_before + v_lost_total = 4 and v_surv_before >= 1;
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. partial loss subtracts correctly: %s lost of 4, %s surviving, rows with quantity <= 0: %s%s',
             v_lost_total, v_surv_before, v_zero, coalesce(' [' || v_err || ']', '')));
    v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    /* 8. global invariant of the class: no settlement path leaves a zero-quantity stack */
    select count(*) into v_zero from public.fleet_movement_ships where quantity <= 0;
    v_ok := v_zero = 0;
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. fleet_movement_ships has %s row(s) with quantity <= 0', v_zero));
    v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    /* 9. static post-condition of the migration: neither settlement path writes quantity = 0 anymore */
    select count(*) into v_rows from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('settle_moon_destruction_for_battle', 'resolve_expedition_black_hole')
       and (p.prosrc like '%and fms.quantity <= 0;%' or p.prosrc like '%AND quantity<=0;%');
    v_ok := v_rows = 0;
    insert into t_flc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. no live settlement function subtracts before deleting (%s legacy definition(s))', v_rows));
    v_ok_runs := v_ok_runs + case when v_ok then 1 else 0 end;
    v_bad_runs := v_bad_runs + case when v_ok then 0 else 1 end;

    insert into t_flc(resultado, prueba) values ('INFO',
      format('LIMITATION: single-session harness, no concurrency. The moon rolls are deterministic in the dispatch timestamps, so the harness searched %s dispatch(es) for the "survived + all Deathstars lost" instant; the black hole 50%% loss is structural (loss target is capped at total-1).', v_tries));
    insert into t_flc(resultado, prueba) values ('INFO',
      format('SUMMARY: %s behavioural assertion(s) passed, %s failed.', v_ok_runs, v_bad_runs));

    if v_bad_runs > 0 then
        raise exception 'FLEET SHIP-LOSS QUANTITY CHECK FIXTURE: % failed assertion(s)', v_bad_runs;
    end if;
end;
$test$;

select orden, resultado, prueba from t_flc order by orden;

drop table if exists t_flc;

ROLLBACK;
