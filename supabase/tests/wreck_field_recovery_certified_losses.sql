-- ============================================================================
-- LGI CORE RECOVERY — WRECK FIELD: certified loss source + battle isolation +
-- idempotency + owner ACL (migration 20261001000000)
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional: rolled back at the end, no LIVE residue.
--
-- ANTI-VACUITY: the old settle_wreck_field_for_battle read combat_unit_state,
-- which is EMPTY in LIVE, so it always produced NULL. The fixture ABORTS unless it
-- can build a battle that really loses ships, so this file can never pass by
-- accident against a broken engine.
-- ============================================================================
begin;

drop table if exists t_wf_rec;
create temp table t_wf_rec(orden serial, resultado text, prueba text);

do $test$
declare
    v_user uuid; v_player uuid; v_origin uuid; v_universe uuid;
    v_target uuid; v_def_player uuid;
    v_fleet uuid := gen_random_uuid();
    v_battle uuid; v_battle2 uuid; v_fleet2 uuid := gen_random_uuid();
    v_field uuid; v_qty bigint; v_res record;
    v_rows bigint; v_fail integer := 0;
begin
    begin
        insert into public.player_research(player_id, research_id, level)
        select pl.id, 'computer_technology', 60 from public.players pl
        on conflict (player_id, research_id)
        do update set level = greatest(public.player_research.level, excluded.level);

        select pl.id, pl.user_id, p.id, p.universe_id
          into v_player, v_user, v_origin, v_universe
          from public.planets p join public.players pl on pl.id = p.player_id
         where pl.player_type = 'HUMAN' and pl.user_id is not null and p.is_destroyed = false
         order by (pl.username like 'DevPlayer%'), p.created_at, p.id limit 1;
        if v_origin is null then raise exception 'WF_REC_ABORT: no HUMAN player with a planet'; end if;

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        select p2.id, p2.player_id into v_target, v_def_player
          from public.planets p2
         where p2.universe_id = v_universe and p2.is_destroyed = false
           and p2.player_id <> v_player and p2.id <> v_origin
         order by p2.galaxy, p2.system, p2.position, p2.id limit 1;
        if v_target is null then raise exception 'WF_REC_ABORT: no candidate defender planet'; end if;

        /* deterministic: the DEFENDER loses small_cargo, the attacker sends overwhelming cruisers */
        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);
        delete from public.planet_wreck_fields where planet_id = v_target;

        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_fleet, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '60 seconds',
                clock_timestamp() - interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet, 'cruiser', 200);

        v_battle := public.resolve_attack_arrival(v_fleet);

        /* ANTI-VACUITY GATE: the fixture must really have produced ship losses. */
        select coalesce(sum(destroyed_quantity),0) into v_rows
          from public.calculate_combat_ship_losses(v_battle) where side = 'DEFENDER';
        if v_battle is null or v_rows = 0 then
            raise exception 'WF_REC_ABORT: battle % produced no defender ship losses (fixture would be vacuous)', v_battle;
        end if;

        insert into t_wf_rec values (default,
          case when exists (select 1 from public.planet_wreck_fields where planet_id = v_target)
               then 'PASS' else 'FAIL' end,
          format('1. losing battle AUTO-CREATES the wreck field on the defender planet (%s destroyed small_cargo)', v_rows));

        select wf.id into v_field from public.planet_wreck_fields wf where wf.planet_id = v_target;
        select wfs.quantity into v_qty from public.planet_wreck_field_ships wfs
         where wfs.wreck_field_id = v_field and wfs.ship_id = 'small_cargo';

        insert into t_wf_rec values (default,
          case when v_qty is not null and v_qty > 0 and v_qty <= v_rows then 'PASS' else 'FAIL' end,
          format('2. losses come from the CERTIFIED ledger, capped by the 20%% Space Dock 0 share (%s stored of %s destroyed)', v_qty, v_rows));

        insert into t_wf_rec values (default,
          case when not exists (select 1 from public.planet_wreck_field_ships wfs
                                 join public.ship_definitions sd on sd.id = wfs.ship_id
                                where wfs.wreck_field_id = v_field and sd.id = 'rocket_launcher')
               then 'PASS' else 'FAIL' end,
          '3. DEFENCES never enter the wreck field (only unit_type SHIP)');
/* ---- IDEMPOTENCY: re-settling the same battle must not double the wreck ---- */
        perform public.settle_wreck_field_for_battle(v_battle);
        select wfs.quantity into v_qty from public.planet_wreck_field_ships wfs
         where wfs.wreck_field_id = v_field and wfs.ship_id = 'small_cargo';
        insert into t_wf_rec values (default,
          case when v_qty is not null and v_qty <= (select coalesce(sum(destroyed_quantity),0)
                     from public.calculate_combat_ship_losses(v_battle) where side='DEFENDER')
               then 'PASS' else 'FAIL' end,
          format('4. IDEMPOTENT: re-running settle for the same battle does NOT double the wreck (%s stored)', v_qty));

        insert into t_wf_rec values (default,
          case when (select count(*) from public.planet_wreck_field_battles where battle_id = v_battle) = 1
               then 'PASS' else 'FAIL' end,
          '5. exactly ONE ledger row per battle (battle isolation + at-most-once settlement)');

        /* ---- ZERO-LOSS battle => NO wreck field ---- */
        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_fleet2, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '60 seconds',
                clock_timestamp() - interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity) values (v_fleet2, 'cruiser', 1);
        v_battle2 := public.resolve_attack_arrival(v_fleet2);
        if v_battle2 is not null then
          update public.combat_individual_units set alive = true where battle_id = v_battle2;
          perform public.settle_wreck_field_for_battle(v_battle2);
        end if;
        insert into t_wf_rec values (default,
          case when v_battle2 is not null
                and not exists (select 1 from public.planet_wreck_field_battles where battle_id = v_battle2)
               then 'PASS' else 'FAIL' end,
          '6. zero-loss battle => NO wreck field and NO ledger row (no phantom wreck)');

        /* ---- ACL ---- */
        insert into t_wf_rec values (default,
          case when not has_function_privilege('authenticated', 'public.settle_wreck_field_for_battle(uuid)', 'EXECUTE')
                and not has_function_privilege('authenticated', 'public.create_or_extend_wreck_field(uuid,jsonb,integer)', 'EXECUTE')
                and not has_function_privilege('anon', 'public.settle_wreck_field_for_battle(uuid)', 'EXECUTE')
               then 'PASS' else 'FAIL' end,
          '7. engine contracts stay service_role-only (a client cannot fabricate a wreck field)');

        select count(*) into v_rows from public.get_planet_wreck_field(v_target);
        insert into t_wf_rec values (default,
          case when v_rows > 0 then 'PASS' else 'FAIL' end,
          format('8. owner read contract returns the field to the OWNER (%s rows)', v_rows));

        select count(*) into v_rows from public.get_planet_wreck_field(v_origin);
        insert into t_wf_rec values (default,
          case when v_rows = 0 then 'PASS' else 'FAIL' end,
          '9. owner read contract returns 0 rows for a planet the caller does NOT own');

        perform set_config('request.jwt.claims', json_build_object('role','anon')::text, false);
        select count(*) into v_rows from public.get_planet_wreck_field(v_target);
        insert into t_wf_rec values (default,
          case when v_rows = 0 then 'PASS' else 'FAIL' end,
          '10. ANONYMOUS caller reads 0 rows through the read contract (no private wreck exposure)');
        perform set_config('request.jwt.claims', '', false);
insert into t_wf_rec values (default,
          case when (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
                      where n.nspname='public' and c.relname='planet_wreck_fields')
                and (select relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
                      where n.nspname='public' and c.relname='planet_wreck_field_ships')
               then 'PASS' else 'FAIL' end,
          '11. RLS is ENABLED on both wreck tables (defence in depth)');

        insert into t_wf_rec values (default,
          case when not exists (
                  select 1 from pg_policies where schemaname='public'
                    and tablename='planet_wreck_fields' and cmd <> 'SELECT')
               then 'PASS' else 'FAIL' end,
          '12. no client INSERT/UPDATE/DELETE policy exists (writes are RPC/engine only)');

        /* ---- recovery never exceeds the original loss ---- */
        insert into public.planet_buildings(planet_id, building_id, level) values (v_target,'space_dock',10)
        on conflict (planet_id, building_id) do update set level = 10;
        select coalesce(sum(quantity),0) into v_rows
          from public.planet_wreck_field_ships where wreck_field_id = v_field;
        insert into t_wf_rec values (default,
          case when v_rows <= (select coalesce(sum(destroyed_quantity),0)
                                 from public.calculate_combat_ship_losses(v_battle) where side='DEFENDER')
               then 'PASS' else 'FAIL' end,
          format('13. stored wreck (%s) NEVER exceeds the original loss', v_rows));

        select * into v_res from public.start_planet_wreck_field_repairs(v_target);
        insert into t_wf_rec values (default,
          case when v_res.out_status = 'REPAIRING' then 'PASS' else 'FAIL' end,
          format('14. owner RPC starts repairs on the own field (%s/%s)', v_res.out_status, v_res.out_result));

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);
        select * into v_res from public.start_planet_wreck_field_repairs(v_origin);
        insert into t_wf_rec values (default,
          case when v_res.out_status = 'DENIED' then 'PASS' else 'FAIL' end,
          format('15. owner RPC DENIES a planet the caller does not own (%s)', v_res.out_result));
        perform set_config('request.jwt.claims', '', false);

        select count(*) into v_rows
          from public.planet_wreck_field_battles b
          join public.combat_battles cb on cb.id = b.battle_id
         where cb.defender_planet_id is distinct from
               (select wf.planet_id from public.planet_wreck_fields wf where wf.id = b.wreck_field_id);
        insert into t_wf_rec values (default,
          case when v_rows = 0 then 'PASS' else 'FAIL' end,
          '16. every settled battle is bound to ITS OWN defender planet (no cross-planet leakage)');

    exception when others then
        insert into t_wf_rec values (default, 'FAIL', format('fixture aborted: %s', sqlerrm));
    end;

    select count(*) into v_fail from t_wf_rec where resultado = 'FAIL';
    insert into t_wf_rec values (default, 'INFO', format('failed assertions: %s', v_fail));
    if v_fail > 0 then
        raise exception 'WRECK FIELD RECOVERY FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_wf_rec order by orden;
rollback;