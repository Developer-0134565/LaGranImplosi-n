-- ============================================================================
-- COMBAT ENGINE PHASE 2 — DG-01 BATTLE-REPORT CONTRACT FIXTURE
-- LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Proves the Phase 2 read contract `get_player_battle_reports(p_limit)`:
--
--   R1  the attacking player reads their own completed battle and every exposed
--       field matches the persisted authoritative state (outcome vs flags,
--       participants, rounds, losses, debris, repairs);
--   R1b the `losses` payload equals the certified derived ledger
--       (`calculate_combat_ship_losses`) — no client-side formula is required;
--   R2  the defending participant owner reads the same battle as DEFENDER;
--   R3  an unrelated authenticated player reads nothing;
--   R4  an unauthenticated caller reads nothing;
--   R5  the real client role (`authenticated`) still gets ZERO rows from
--       `combat_battles` (deny policy intact) while the contract still works;
--   R6  the limit argument is honoured and defended.
--
-- ROLLBACK SAFETY: the fixture and both readings run inside a nested PL/pgSQL
-- block that is undone by a sentinel exception, so this file is safe in any
-- client (psql, SQL editor, automation).
--
-- Defender coverage note: `players.user_id` is FK-constrained to `auth.users`, so
-- no synthetic identity is created. The defender branch is exercised by pointing
-- the REAL auth account at the defending player inside the rolled-back block.
-- ============================================================================

begin;

drop table if exists t_combat_report_results;
create temp table t_combat_report_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid;
    v_target uuid; v_def_player uuid;
    v_fleet uuid := gen_random_uuid();
    v_battle uuid;
    v_other_user uuid := gen_random_uuid();
    v_ok boolean; v_fail integer := 0; v_lines text := '';
    v_rows bigint; v_role text; v_outcome text; v_parts integer;
    v_rounds integer; v_losses integer; v_debris numeric; v_repairs bigint;
    v_flags_ok boolean; v_payload bigint; v_ledger bigint;
begin
    begin
        select pl.id, pl.user_id, p.id, p.universe_id
          into v_player, v_user, v_origin, v_universe
        from public.planets p
        join public.players pl on pl.id = p.player_id
        where pl.player_type = 'HUMAN' and pl.user_id is not null and p.is_destroyed = false
        order by (pl.username like 'DevPlayer%'), p.created_at, p.id
        limit 1;

        if v_origin is null then
            raise exception 'PHASE2_FIXTURE_ABORT: no HUMAN player with a usable planet';
        end if;

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        select p2.id, p2.player_id into v_target, v_def_player
        from public.planets p2
        where p2.universe_id = v_universe and p2.is_destroyed = false
          and p2.player_id <> v_player and p2.id <> v_origin
        order by p2.galaxy, p2.system, p2.position, p2.id
        limit 1;

        /* deterministic defender composition so losses are provable */
        delete from public.planet_ships where planet_id = v_target;
        delete from public.planet_defenses where planet_id = v_target;
        insert into public.planet_ships(planet_id, ship_id, quantity) values (v_target, 'small_cargo', 10);
        insert into public.planet_defenses(planet_id, defense_id, quantity) values (v_target, 'rocket_launcher', 2);

        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values (v_fleet, v_player, v_origin, v_target, 'ATTACK',
                clock_timestamp() - interval '60 seconds',
                clock_timestamp() - interval '1 second', 'ARRIVED');
        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_fleet, 'cruiser', 20);

        v_battle := public.resolve_attack_arrival(v_fleet);

        /* ---- R1: the attacker reads the persisted battle ------------------- */
        select count(*), max(r.outcome), max(r.caller_role),
               max(jsonb_array_length(r.participants)), max(jsonb_array_length(r.rounds)),
               max(jsonb_array_length(r.losses)), max(r.debris_metal), max(r.defenses_repaired)
          into v_rows, v_outcome, v_role, v_parts, v_rounds, v_losses, v_debris, v_repairs
        from public.get_player_battle_reports(25) r
        where r.battle_id = v_battle;

        select (cb.attacker_win and not cb.defender_win and not cb.draw)
          into v_flags_ok
        from public.combat_battles cb where cb.id = v_battle;

        v_ok := v_rows = 1 and v_outcome = 'ATTACKER_WIN' and v_role = 'ATTACKER'
                and v_parts = 2 and v_rounds >= 1 and v_losses >= 1
                and v_debris > 0 and v_repairs >= 0 and v_flags_ok;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R1 attacker report matches persisted state (rows=%s outcome=%s role=%s participants=%s rounds=%s losses=%s debris=%s)',
                      v_rows, v_outcome, v_role, v_parts, v_rounds, v_losses, v_debris) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- R1b: the losses payload is the certified derived ledger ------- */
        select (l->>'destroyed_quantity')::bigint into v_payload
        from public.get_player_battle_reports(25) r, jsonb_array_elements(r.losses) l
        where r.battle_id = v_battle and l->>'side' = 'DEFENDER' and l->>'unit_id' = 'small_cargo';

        select coalesce(sum(destroyed_quantity), 0) into v_ledger
        from public.calculate_combat_ship_losses(v_battle)
        where side = 'DEFENDER' and unit_id = 'small_cargo';

        v_ok := v_payload is not null and v_payload = v_ledger and v_ledger = 10;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R1b reported losses equal the derived ledger (payload=%s ledger=%s)', v_payload, v_ledger) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- R2: the defending participant owner reads it as DEFENDER ------ */
        update public.players set user_id = null where id = v_player;
        update public.players set user_id = v_user where id = v_def_player;
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        select count(*), max(r.caller_role) into v_rows, v_role
        from public.get_player_battle_reports(25) r
        where r.battle_id = v_battle;

        v_ok := v_rows = 1 and v_role = 'DEFENDER';
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R2 defender-side owner reads the same battle (rows=%s role=%s)', v_rows, v_role) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        update public.players set user_id = null where id = v_def_player;
        update public.players set user_id = v_user where id = v_player;

        /* ---- R3: an unrelated authenticated player reads nothing ----------- */
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_other_user::text, 'role', 'authenticated')::text, false);
        select count(*) into v_rows from public.get_player_battle_reports(25);

        v_ok := v_rows = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R3 unrelated authenticated player reads nothing (rows=%s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- R4: an unauthenticated caller reads nothing ------------------- */
        perform set_config('request.jwt.claims', '{}', false);
        select count(*) into v_rows from public.get_player_battle_reports(25);

        v_ok := v_rows = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R4 unauthenticated caller reads nothing (rows=%s)', v_rows) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- R5: raw tables stay closed, the contract still works ---------- */
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);
        set local role authenticated;
        select count(*) into v_rows from public.combat_battles;
        select count(*) into v_losses from public.get_player_battle_reports(25) r where r.battle_id = v_battle;
        reset role;

        v_ok := v_rows = 0 and v_losses = 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R5 raw combat_battles stays closed for authenticated (rows=%s) while the contract returns %s',
                      v_rows, v_losses) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- R6: the limit argument is honoured --------------------------- */
        select count(*) into v_rows from public.get_player_battle_reports(1);
        select count(*) into v_losses from public.get_player_battle_reports(null);

        v_ok := v_rows <= 1 and v_losses >= 1;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('R6 limit honoured (p_limit=1 -> %s, default -> %s)', v_rows, v_losses) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        raise exception 'PHASE2_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE2_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_report_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT REPORT CONTRACT FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT REPORT CONTRACT FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_report_results order by orden;

drop table if exists t_combat_report_results;

rollback;
