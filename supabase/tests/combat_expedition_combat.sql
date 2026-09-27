-- ============================================================================
-- COMBAT ENGINE PHASE 1 — EXPEDITION COMBAT PROOF (CB-01) — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION.
--
-- Phase 0 (CB-01, HIGH) established that expedition pirate/alien battles were
-- created without combat participants and with raw ship_definitions statistics,
-- so the participant-aware damage ledger could never resolve damage: the battle
-- ran to the 6-round boundary and always ended as a DRAW with no losses.
--
-- This fixture proves the repaired contract on the REAL production functions
-- (`resolve_expedition_pirates` / `resolve_expedition_aliens`, both reachable
-- from the fleet worker through `resolve_expedition_arrival`):
--
--   expedition fleet (EXPEDITION, ARRIVED) → expedition battle
--   → ATTACKER/FLEET + DEFENDER/ENEMY participants
--   → every combat unit carries participant_id
--   → round snapshot + damage ledger resolve real damage
--   → units die, losses become derivable, result is persisted and finished
--
-- ROLLBACK SAFETY: fixture + battles run inside a nested PL/pgSQL block whose
-- changes are undone by a sentinel exception before the block exits, so it is
-- safe in any client (psql, SQL editor, automation).
--
-- Deterministic synthetic fleet UUIDs are used so the expedition RNG tiers are
-- reproducible; NO live identifier is hardcoded.
-- ============================================================================

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_combat_expedition_results;
create temp table t_combat_expedition_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_player uuid; v_user uuid; v_origin uuid; v_universe uuid;
    v_pirates_fleet uuid := '11111111-2222-4333-8444-555555555501';
    v_aliens_fleet  uuid := '11111111-2222-4333-8444-555555555502';
    v_battle uuid; v_result text;
    v_att uuid; v_enemy uuid;
    v_att_units bigint; v_def_units bigint; v_null bigint;
    v_snap bigint; v_dmg bigint; v_dmg_total numeric;
    v_finished boolean; v_flags integer; v_alive_def bigint; v_alive_att bigint;
    v_ships bigint;
    v_ok boolean; v_fail integer := 0; v_lines text := '';
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
            raise exception 'PHASE1_FIXTURE_ABORT: no HUMAN player with a usable planet';
        end if;

        perform set_config('request.jwt.claims',
            json_build_object('sub', v_user::text, 'role', 'authenticated')::text, false);

        insert into public.fleet_movements(
            id, player_id, origin_planet_id, destination_planet_id, mission_type,
            started_at, arrives_at, status)
        values
            (v_pirates_fleet, v_player, v_origin, null, 'EXPEDITION',
             clock_timestamp() - interval '120 seconds', clock_timestamp() - interval '60 seconds', 'ARRIVED'),
            (v_aliens_fleet, v_player, v_origin, null, 'EXPEDITION',
             clock_timestamp() - interval '120 seconds', clock_timestamp() - interval '60 seconds', 'ARRIVED');

        insert into public.fleet_movement_ships(fleet_id, ship_id, quantity)
        values (v_pirates_fleet, 'cruiser', 20), (v_aliens_fleet, 'cruiser', 20);

        /* ================= SCENARIO 1 — PIRATE ENCOUNTER ================= */
        select x.battle_id, x.battle_result into v_battle, v_result
        from public.resolve_expedition_pirates(v_pirates_fleet) x;

        /* ---- P1 participants: real fleet + NPC hostile side ---- */
        select id into v_att from public.combat_battle_participants
        where battle_id = v_battle and side = 'ATTACKER' and participant_type = 'FLEET'
          and fleet_id = v_pirates_fleet and player_id = v_player and origin_planet_id = v_origin;

        select id into v_enemy from public.combat_battle_participants
        where battle_id = v_battle and side = 'DEFENDER' and participant_type = 'ENEMY'
          and player_id is null and fleet_id is null and planet_id is null and origin_planet_id is null;

        v_ok := v_att is not null and v_enemy is not null
            and (select count(*) from public.combat_battle_participants where battle_id = v_battle) = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'P1 pirate battle has ATTACKER/FLEET + DEFENDER/ENEMY participants' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P2 units carry participant identity ---- */
        select count(*) filter (where side = 'ATTACKER' and participant_id = v_att),
               count(*) filter (where side = 'DEFENDER' and participant_id = v_enemy),
               count(*) filter (where participant_id is null)
          into v_att_units, v_def_units, v_null
        from public.combat_individual_units
        where battle_id = v_battle and round_number = 1;

        v_ok := v_att_units = 20 and v_def_units > 0 and v_null = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P2 pirate units attributed (attacker=%s, enemy=%s, null=%s)',
                      v_att_units, v_def_units, v_null) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P3 round snapshot ---- */
        select count(*), count(*) filter (where participant_id is null)
          into v_snap, v_null
        from public.combat_round_snapshot_units where battle_id = v_battle;

        v_ok := v_snap > 0 and v_null = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P3 pirate snapshot rows=%s, null participants=%s', v_snap, v_null) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P4 damage ledger resolves REAL damage (the CB-01 proof) ---- */
        select count(*), count(*) filter (where target_participant_id is null),
               coalesce(sum(shield_damage + hull_damage), 0)
          into v_dmg, v_null, v_dmg_total
        from public.combat_round_damage where battle_id = v_battle;

        v_ok := v_dmg > 0 and v_null = 0 and v_dmg_total > 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P4 pirate damage ledger rows=%s, total damage=%s', v_dmg, v_dmg_total) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P5 result persisted ---- */
        select cb.finished_at is not null,
               (case when cb.attacker_win then 1 else 0 end)
             + (case when cb.defender_win then 1 else 0 end)
             + (case when cb.draw then 1 else 0 end)
          into v_finished, v_flags
        from public.combat_battles cb where cb.id = v_battle;

        v_ok := v_finished and v_flags = 1
            and v_result in ('ATTACKER_WIN','DEFENDER_WIN','DRAW');
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P5 pirate battle finished with one flag, result=%s', v_result) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P6 losses are produced and derivable ---- */
        select count(*) filter (where side = 'DEFENDER' and alive) into v_alive_def
        from public.combat_individual_units
        where battle_id = v_battle
          and round_number = (select max(round_number) from public.combat_individual_units where battle_id = v_battle);

        v_ok := v_alive_def = 0
            and coalesce((select sum(destroyed_quantity) from public.calculate_combat_ship_losses(v_battle)
                          where side = 'DEFENDER'), 0) > 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P6 pirate defenders destroyed and losses derivable (left=%s)', v_alive_def) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- P7 survivor write-back uses the FINAL round only ---- */
        select count(*) filter (where side = 'ATTACKER' and alive) into v_alive_att
        from public.combat_individual_units
        where battle_id = v_battle
          and round_number = (select max(round_number) from public.combat_individual_units where battle_id = v_battle);

        select coalesce(sum(quantity), 0) into v_ships
        from public.fleet_movement_ships where fleet_id = v_pirates_fleet;

        v_ok := v_ships = v_alive_att and v_ships <= 20;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('P7 pirate survivors written back from the final round (fleet=%s, alive=%s)',
                      v_ships, v_alive_att) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ================= SCENARIO 2 — ALIEN ENCOUNTER ================= */
        select x.battle_id, x.result into v_battle, v_result
        from public.resolve_expedition_aliens(v_aliens_fleet) x;

        /* ---- A1 participants ---- */
        select id into v_att from public.combat_battle_participants
        where battle_id = v_battle and side = 'ATTACKER' and participant_type = 'FLEET'
          and fleet_id = v_aliens_fleet and player_id = v_player and origin_planet_id = v_origin;

        select id into v_enemy from public.combat_battle_participants
        where battle_id = v_battle and side = 'DEFENDER' and participant_type = 'ENEMY'
          and player_id is null and fleet_id is null;

        v_ok := v_att is not null and v_enemy is not null
            and (select count(*) from public.combat_battle_participants where battle_id = v_battle) = 2;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || 'A1 alien battle has ATTACKER/FLEET + DEFENDER/ENEMY participants' || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- A2 units carry participant identity ---- */
        select count(*) filter (where side = 'ATTACKER' and participant_id = v_att),
               count(*) filter (where side = 'DEFENDER' and participant_id = v_enemy),
               count(*) filter (where participant_id is null)
          into v_att_units, v_def_units, v_null
        from public.combat_individual_units
        where battle_id = v_battle and round_number = 1;

        v_ok := v_att_units = 20 and v_def_units > 0 and v_null = 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('A2 alien units attributed (attacker=%s, enemy=%s, null=%s)',
                      v_att_units, v_def_units, v_null) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- A3 damage ledger resolves real damage ---- */
        select count(*), count(*) filter (where target_participant_id is null),
               coalesce(sum(shield_damage + hull_damage), 0)
          into v_dmg, v_null, v_dmg_total
        from public.combat_round_damage where battle_id = v_battle;

        v_ok := v_dmg > 0 and v_null = 0 and v_dmg_total > 0;
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('A3 alien damage ledger rows=%s, total damage=%s', v_dmg, v_dmg_total) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- A4 result persisted and survivors consistent ---- */
        select cb.finished_at is not null,
               (case when cb.attacker_win then 1 else 0 end)
             + (case when cb.defender_win then 1 else 0 end)
             + (case when cb.draw then 1 else 0 end)
          into v_finished, v_flags
        from public.combat_battles cb where cb.id = v_battle;

        select count(*) filter (where side = 'ATTACKER' and alive) into v_alive_att
        from public.combat_individual_units
        where battle_id = v_battle
          and round_number = (select max(round_number) from public.combat_individual_units where battle_id = v_battle);

        select coalesce(sum(quantity), 0) into v_ships
        from public.fleet_movement_ships where fleet_id = v_aliens_fleet;

        v_ok := v_finished and v_flags = 1 and v_ships = v_alive_att
            and v_result in ('ATTACKER_WIN','DEFENDER_WIN','DRAW');
        v_lines := v_lines || case when v_ok then 'PASS|' else 'FAIL|' end
            || format('A4 alien battle finished (result=%s, fleet=%s, alive=%s)',
                      v_result, v_ships, v_alive_att) || E'\n';
        v_fail := v_fail + case when v_ok then 0 else 1 end;

        /* ---- end of fixture: undo every change made by this block ---- */
        raise exception 'PHASE1_FIXTURE_ROLLBACK';
    exception
        when others then
            if sqlerrm <> 'PHASE1_FIXTURE_ROLLBACK' then
                v_fail := v_fail + 1;
                v_lines := v_lines || 'FAIL|99 unexpected error: ' || sqlerrm || E'\n';
            end if;
    end;

    perform set_config('request.jwt.claims', '{}', false);

    insert into t_combat_expedition_results(resultado, prueba)
    select split_part(line, '|', 1), split_part(line, '|', 2)
    from unnest(string_to_array(v_lines, E'\n')) as line
    where line <> '';

    if v_fail > 0 then
        raise exception 'COMBAT EXPEDITION FIXTURE: % failed assertion(s) -> %',
            v_fail, replace(v_lines, E'\n', '');
    end if;

    raise notice 'COMBAT EXPEDITION FIXTURE: all assertions passed (fixture rolled back)';
end
$test$;

select orden, resultado, prueba from t_combat_expedition_results order by orden;

drop table if exists t_combat_expedition_results;

rollback;
