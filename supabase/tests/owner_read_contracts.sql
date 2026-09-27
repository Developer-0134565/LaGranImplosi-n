-- OWNER-SCOPED READ CONTRACTS FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260926140000_add_owner_read_contracts_espionage_and_messages):
--   * `get_player_espionage_reports(limit)` — only the reports of the players owned by `auth.uid()`
--     (a report belongs to the attacker), with the target coordinates joined in; limit clamped 1..200;
--   * `get_player_messages(limit, unread_only)` — only the inbox of the players owned by `auth.uid()`;
--   * `mark_message_read(id)` — recipient-only, writes `read_at` once (idempotent), refuses anything else
--     without mutating;
--   * all three: EXECUTE for authenticated/service_role only (never anon).
--
-- LIMITATION: single-session harness; concurrency is not executed. The foreign report/message are created
-- directly by the fixture (postgres) because the caller cannot write another player's rows — that is the state
-- under test.

begin;

/* FLEET SLOTS PREREQUISITE (2026-09-26): the engine now enforces 1 + computer_technology simultaneous fleets
   on every fleet_movements insert (trigger trg_enforce_fleet_slots). This fixture needs several live
   movements at once, so it grants a high computer_technology level to every player before exercising its
   contract. See supabase/tests/fleet_slots_enforcement.sql for the enforcement fixture. */
insert into public.player_research(player_id, research_id, level)
select pl.id, 'computer_technology', 60
from public.players pl
on conflict (player_id, research_id) do update set level = greatest(public.player_research.level, excluded.level);


drop table if exists t_rc;
create temp table t_rc(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid; v_player uuid; v_planet uuid;
    v_foreign_player uuid; v_foreign_planet uuid;
    v_fleet_mine uuid; v_fleet_anchor uuid;
    v_rows integer; v_after_rows integer; v_ok boolean; v_fail integer := 0;
    v_blocked boolean; v_err text;
    v_row record;
    v_msg_id uuid; v_flag boolean;
    v_read_before timestamptz; v_read_after timestamptz;
    v_auth_exec boolean; v_anon_exec boolean;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null order by pl.created_at, pl.id limit 1;

    select p.id into v_planet
      from public.planets p where p.player_id = v_player and not p.is_destroyed order by p.created_at limit 1;

    select pl.id, p.id into v_foreign_player, v_foreign_planet
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.id <> v_player order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_foreign_player is null or v_foreign_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* Two fleets OWNED BY THE CALLER (the write-access trigger allows them): one anchors the caller's own
       report, the other anchors the foreign report (which belongs to another player). */
    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'RETURNING')
    returning id into v_fleet_mine;

    insert into public.fleet_movements(player_id, origin_planet_id, mission_type, arrives_at, status)
    values (v_player, v_planet, 'ESPIONAGE', now() + interval '1 hour', 'OUTBOUND')
    returning id into v_fleet_anchor;

    insert into public.espionage_reports(fleet_id, player_id, target_planet_id, espionage_level,
                                        target_espionage_level, metal, crystal, deuterium, energy, fleet, defenses)
    values (v_fleet_mine, v_player, v_foreign_planet, 5, 2, 111, 222, 333, 444,
            '{"light_fighter": 7}'::jsonb, '{"rocket_launcher": 3}'::jsonb);

    insert into public.espionage_reports(fleet_id, player_id, target_planet_id, espionage_level,
                                        target_espionage_level, metal, crystal, deuterium, energy)
    values (v_fleet_anchor, v_foreign_player, v_planet, 9, 1, 9999, 9999, 9999, 9999);

    /* Messages: two for the caller (one already read) and one for the foreign player. */
    insert into public.player_messages(recipient_player_id, subject, body)
    values (v_player, 'FIXTURE unread', 'body-unread');

    insert into public.player_messages(recipient_player_id, subject, body, read_at)
    values (v_player, 'FIXTURE read', 'body-read', now());

    insert into public.player_messages(recipient_player_id, subject, body)
    values (v_foreign_player, 'FIXTURE foreign', 'body-foreign');

    /* ------------------------------------------------- 1. ESPIONAGE: OWNERSHIP ISOLATION */
    select count(*)::integer into v_rows
      from public.get_player_espionage_reports(100) r
     where r.out_player_id = v_player;
    v_ok := v_rows = 1;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. only the caller''s own espionage report is returned (%s row; the foreign report is invisible)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------- 2. ESPIONAGE: FULL PAYLOAD + COORDINATES */
    select * into v_row
      from public.get_player_espionage_reports(100) r
     where r.out_player_id = v_player;

    v_ok := v_row.out_target_planet_id = v_foreign_planet
        and v_row.out_espionage_level = 5
        and v_row.out_target_espionage_level = 2
        and v_row.out_metal = 111 and v_row.out_crystal = 222
        and v_row.out_deuterium = 333 and v_row.out_energy = 444
        and v_row.out_fleet = '{"light_fighter": 7}'::jsonb
        and v_row.out_defenses = '{"rocket_launcher": 3}'::jsonb
        and v_row.out_galaxy = (select p.galaxy from public.planets p where p.id = v_foreign_planet)
        and v_row.out_position = (select p.position from public.planets p where p.id = v_foreign_planet);
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. report payload intact: levels %s/%s, resources %s/%s/%s/%s, target %s:%s:%s',
             v_row.out_espionage_level, v_row.out_target_espionage_level, v_row.out_metal, v_row.out_crystal,
             v_row.out_deuterium, v_row.out_energy, v_row.out_galaxy, v_row.out_system, v_row.out_position));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------------------- 3. ESPIONAGE: LIMIT CLAMP */
    select count(*)::integer into v_rows from public.get_player_espionage_reports(0) r;
    v_ok := v_rows = 1;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. espionage limit clamped to >= 1 (asked 0, got %s row)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 4. MESSAGES: OWNERSHIP ISOLATION */
    select count(*)::integer into v_rows from public.get_player_messages(100, false) r;
    v_ok := v_rows = 2;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the inbox shows only the caller''s own messages (%s of 3 rows; the foreign one is invisible)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------------ 5. MESSAGES: UNREAD FILTER */
    select count(*)::integer into v_rows from public.get_player_messages(100, true) r;
    v_ok := v_rows = 1 and exists (select 1 from public.get_player_messages(100, true) r where r.out_subject = 'FIXTURE unread');
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. unread filter returns exactly the unread message (%s row)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 6. MARK READ: FIRST CALL WRITES */
    select r.out_message_id into v_msg_id
      from public.get_player_messages(100, true) r
     where r.out_subject = 'FIXTURE unread';

    select m.out_already_read, m.out_read_at into v_flag, v_read_after
      from public.mark_message_read(v_msg_id) m;

    select count(*)::integer into v_rows from public.get_player_messages(100, true) r;
    v_ok := v_flag = false and v_read_after is not null and v_rows = 0;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. first mark_message_read stamps read_at (unread left: %s)', v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ------------------------------------------------------ 7. MARK READ: IDEMPOTENT */
    v_read_before := v_read_after;

    select m.out_already_read, m.out_read_at into v_flag, v_read_after
      from public.mark_message_read(v_msg_id) m;

    v_ok := v_flag = true and v_read_after = v_read_before;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. replay: a second mark_message_read reports already_read and never moves read_at (%s)', v_read_after));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------- 8. FOREIGN / UNKNOWN MESSAGE IS REFUSED WITHOUT MUTATION */
    select count(*)::integer into v_rows
      from public.player_messages pm where pm.read_at is null;

    v_blocked := false; v_err := null;
    begin
        perform public.mark_message_read(gen_random_uuid());
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err like 'PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED%';
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8a. unknown message refused [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* the foreign message (inserted by the fixture for another player) must be unreachable */
    select count(*)::integer into v_rows
      from public.player_messages pm
     where pm.recipient_player_id = v_foreign_player;
    if v_rows = 0 then
        raise exception 'TEST_ABORT: the foreign message row is missing';
    end if;

    v_blocked := false; v_err := null;
    begin
        perform public.mark_message_read((select pm.id from public.player_messages pm
                                           where pm.recipient_player_id = v_foreign_player limit 1));
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select count(*)::integer into v_rows from public.player_messages pm where pm.read_at is null;

    v_ok := v_blocked and v_err like 'PLAYER_MESSAGE_NOT_FOUND_OR_NOT_OWNED%' and v_rows = 1;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8b. another player''s message refused and still unread [%s; unread rows left: %s]', v_blocked, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* --------------------------------------------------- 9. UNAUTHENTICATED CALLER */
    perform set_config('request.jwt.claims', '{}', true);

    v_blocked := false; v_err := null;
    begin
        perform public.mark_message_read(v_msg_id);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and v_err = 'Authentication required';
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9a. unauthenticated mark_message_read refused [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select count(*)::integer into v_rows from public.get_player_espionage_reports(100) r;
    select count(*)::integer into v_after_rows from public.get_player_messages(100, false) r;
    v_ok := v_rows = 0 and v_after_rows = 0;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9b. without a session both read contracts return nothing (%s reports, %s messages)', v_rows, v_after_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------------------------------------------- 10. ACL BOUNDARY */
    select has_function_privilege('authenticated', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.get_player_messages(integer,boolean)', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.mark_message_read(uuid)', 'EXECUTE')
      into v_auth_exec;

    select has_function_privilege('anon', 'public.get_player_espionage_reports(integer)', 'EXECUTE')
        or has_function_privilege('anon', 'public.get_player_messages(integer,boolean)', 'EXECUTE')
        or has_function_privilege('anon', 'public.mark_message_read(uuid)', 'EXECUTE')
      into v_anon_exec;

    v_ok := v_auth_exec and not v_anon_exec;
    insert into t_rc(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. ACL: authenticated=%s anon=%s for all three read contracts', v_auth_exec, v_anon_exec));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_rc(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. Foreign rows are created directly by the fixture because a caller cannot write another player''s data.');

    if v_fail > 0 then
        raise exception 'OWNER READ CONTRACTS FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_rc order by orden;

drop table if exists t_rc;

ROLLBACK;


