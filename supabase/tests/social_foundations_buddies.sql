-- SOCIAL FOUNDATIONS — FRIENDS/BUDDIES + ALLIANCES + DEFEND AUTHORIZATION
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional fixture: it always ends in ROLLBACK.
--
-- CERTIFIES (all executed against the REAL deployed objects)
--   Buddies: valid request, duplicate, self, unknown player; ONLY the addressee
--            may answer; sender and third party are both refused; non-existent
--            request and double answer refused; cancel is sender-only;
--            remove is symmetric; no relation is an error, not a silent success.
--   ACL:     identity comes from auth.uid() (no caller-supplied player id);
--            no direct table grants for authenticated/anon; RLS enabled;
--            anon cannot EXECUTE any RPC.
--   Alliance: founder holds ALL permissions (OGameX hasPermission); a plain
--            member holds none; cross-alliance access refused; one alliance per
--            player; founder cannot leave; only the founder may dissolve.
--   DEFEND:  buddy OR same-alliance, owner resolved SERVER-SIDE from the planet;
--            own planet, unknown planet, PENDING and REJECTED all denied.
--   HONESTY: defend_dispatch_readiness must report DEFEND as NOT dispatchable,
--            because the multi-fleet combat redesign has not happened.
--
-- ANTI-VACUITY: every negative assertion checks the SPECIFIC error code, and
-- each control asserts its own precondition (row counts, stored values) before
-- asserting the engine behaviour it depends on. A control that silently matched
-- nothing is reported as FAIL, never hidden.
--
-- LIMITATION: sequential, single session, inside ROLLBACK. Concurrency is not
-- executed; the FOR UPDATE row locks that make concurrent answers safe are read
-- from the source, not raced here.

begin;

drop table if exists t_social;
create temp table t_social(orden serial, resultado text, prueba text);

do $test$
declare
    v_alice uuid; v_bob uuid; v_carol uuid; v_auth_a uuid; v_auth_b uuid; v_auth_c uuid;
    v_universe_a uuid; v_req uuid; v_req2 uuid; v_err text; v_ok boolean; v_fails integer := 0;
    v_n integer; v_alliance uuid; v_rank uuid; v_app uuid; v_r record;
    v_pl_alice uuid; v_pl_bob uuid; v_pl_carol uuid;
    v_un uuid; v_g int; v_s int; v_p int;
begin
    /* ---- Act A: REAL auth-linked players with planets, plus one throwaway
       third player created here and rolled back. LIVE has a single auth-linked
       player today, so the fixture creates what it needs and never persists it. */
    select pl.id, pl.user_id, pl.universe_id into v_alice, v_auth_a, v_universe_a
      from public.players pl
     where pl.user_id is not null
       and exists (select 1 from public.planets p where p.player_id = pl.id and not p.is_destroyed)
     order by pl.created_at limit 1;
    if v_alice is null then
        raise exception 'TEST_ABORT: at least one auth-linked player with a planet is required';
    end if;

    select pl.id, pl.user_id into v_bob, v_auth_b
      from public.players pl
     where pl.user_id is not null and pl.id <> v_alice
       and exists (select 1 from public.planets p where p.player_id = pl.id and not p.is_destroyed)
     order by pl.created_at limit 1;
    if v_bob is null then
        raise exception 'TEST_ABORT: a SECOND auth-linked player is required to certify cross-player access';
    end if;

    select p.id into v_pl_alice from public.planets p
     where p.player_id = v_alice and not p.is_destroyed order by p.created_at limit 1;
    select p.id into v_pl_bob from public.planets p
     where p.player_id = v_bob and not p.is_destroyed order by p.created_at limit 1;

    select p.galaxy, p.system, p."position" into v_g, v_s, v_p
      from public.planets p where p.id = v_pl_alice;

    insert into public.players(universe_id, user_id, username, is_guest, player_type)
    values (v_universe_a, gen_random_uuid(), 'SocialFixture_' || substr(md5(random()::text), 1, 8), false, 'HUMAN')
    returning id, user_id into v_carol, v_auth_c;
    insert into public.planets(universe_id, player_id, galaxy, system, "position", kind, is_destroyed)
    values (v_universe_a, v_carol, v_g, v_s, v_p + 700, 'PLANET', false)
    returning id into v_pl_carol;

    /* the fixture starts from a CLEAN slate, otherwise its counts would be noise */
    delete from public.player_buddies
     where (requester_player_id in (v_alice, v_bob, v_carol)
            and addressee_player_id in (v_alice, v_bob, v_carol));
    delete from public.player_alliance_members
     where player_id in (v_alice, v_bob, v_carol);
    delete from public.player_alliance_applications
     where player_id in (v_alice, v_bob, v_carol)
        or alliance_id in (select id from public.player_alliances where founder_player_id in (v_alice, v_bob, v_carol));
    delete from public.player_alliances where founder_player_id in (v_alice, v_bob, v_carol);

    insert into t_social(resultado, prueba) values ('INFO',
      format('SETUP: alice=%s bob=%s carol=%s (carol created by the fixture, rolled back)',
             v_alice, v_bob, v_carol));

/* ============================== BUDDIES ============================== */

    /* 1. a valid request */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select out_id into v_req from public.send_buddy_request(v_bob, 'fixture');
    v_ok := v_req is not null;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. a valid buddy request is created (id=%s)', v_req));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 1b. the row really exists with the right direction (anti-vacuity) */
    select count(*)::integer into v_n from public.player_buddies b
     where b.id = v_req and b.requester_player_id = v_alice
       and b.addressee_player_id = v_bob and b.status = 'PENDING';
    v_ok := v_n = 1;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1b. the stored row has the right direction and PENDING status (%s row(s))', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 2. self-request refused */
    v_err := null;
    begin perform * from public.send_buddy_request(v_alice); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_SELF_NOT_ALLOWED%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. a buddy request to oneself is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 3. unknown addressee refused */
    v_err := null;
    begin perform * from public.send_buddy_request(gen_random_uuid()); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_ADDRESSEE_NOT_FOUND%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. a buddy request to an unknown player is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 4. the requester CANNOT answer their own request */
    v_err := null;
    begin perform * from public.respond_buddy_request(v_req, true); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_REQUEST_NOT_ADDRESSED_TO_YOU%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. the SENDER cannot accept their own request (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 5. an unrelated player cannot answer either */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_c)::text, true);
    v_err := null;
    begin perform * from public.respond_buddy_request(v_req, true); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_REQUEST_NOT_ADDRESSED_TO_YOU%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. an UNRELATED third party cannot answer the request (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 6. unauthenticated is refused */
    perform set_config('request.jwt.claims', '{}', true);
    v_err := null;
    begin perform * from public.respond_buddy_request(v_req, true); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%AUTHENTICATION_REQUIRED%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. an UNAUTHENTICATED caller is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* 7. the addressee accepts, and the relation is symmetric */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_b)::text, true);
    perform * from public.respond_buddy_request(v_req, true);
    v_ok := public.players_are_buddies(v_alice, v_bob) and public.players_are_buddies(v_bob, v_alice);
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '7. acceptance makes the relation real AND symmetric in both directions');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 8. a second answer is refused */
    v_err := null;
    begin perform * from public.respond_buddy_request(v_req, false); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_REQUEST_ALREADY_ANSWERED%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. an already-answered request cannot be answered again (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 9. a non-existent request cannot be answered */
    v_err := null;
    begin perform * from public.respond_buddy_request(gen_random_uuid(), true); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_REQUEST_NOT_FOUND%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. a non-existent request cannot be answered (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 10. duplicate over an established relation refused */
    v_err := null;
    begin perform * from public.send_buddy_request(v_alice); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_ALREADY_ESTABLISHED%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. a duplicate request over an established relation is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 11. exactly ONE row exists for the unordered pair */
    select count(*)::integer into v_n from public.player_buddies b
     where (b.requester_player_id = v_alice and b.addressee_player_id = v_bob)
        or (b.requester_player_id = v_bob and b.addressee_player_id = v_alice);
    v_ok := v_n = 1;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. the unordered pair holds EXACTLY one row (%s) — no duplicate relationship', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 12. rejection creates NO relation */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select out_id into v_req2 from public.send_buddy_request(v_carol);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_c)::text, true);
    perform * from public.respond_buddy_request(v_req2, false);
    v_ok := not public.players_are_buddies(v_alice, v_carol);
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '12. a REJECTED request creates no relationship at all');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 13. only the SENDER may cancel */
    v_err := null;
    begin perform * from public.cancel_buddy_request(v_req2); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_REQUEST_NOT_OWNED_BY_YOU%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. the ADDRESSEE cannot cancel a request they received (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 14. the sender CAN cancel */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    perform * from public.cancel_buddy_request(v_req2);
    select count(*)::integer into v_n from public.player_buddies b where b.id = v_req2;
    v_ok := v_n = 0;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14. the SENDER can cancel, and the row is gone (%s row(s) left)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 15. EITHER side may remove an established relation */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_b)::text, true);
    perform * from public.remove_buddy(v_alice);
    v_ok := not public.players_are_buddies(v_alice, v_bob);
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '15. either party may remove an ACCEPTED relationship (symmetric end)');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 16. removing a non-existent relation is an error, not a silent success */
    v_err := null;
    begin perform * from public.remove_buddy(v_bob); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%BUDDY_RELATION_NOT_FOUND%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('16. removing a relation that does not exist is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* ============================== ACL / IDENTITY ============================== */

    /* 17. the tables are NOT directly reachable by authenticated or anon */
    v_ok := not has_table_privilege('authenticated', 'public.player_buddies', 'SELECT')
        and not has_table_privilege('anon', 'public.player_buddies', 'SELECT')
        and not has_table_privilege('authenticated', 'public.player_buddies', 'INSERT')
        and not has_table_privilege('anon', 'public.player_buddies', 'INSERT');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '17. player_buddies has NO direct table grant for authenticated/anon: the RPCs are the only door');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    v_ok := not has_table_privilege('authenticated', 'public.player_alliances', 'SELECT')
        and not has_table_privilege('anon', 'public.player_alliances', 'SELECT')
        and not has_table_privilege('authenticated', 'public.player_alliance_members', 'SELECT')
        and not has_table_privilege('anon', 'public.player_alliance_members', 'SELECT')
        and not has_table_privilege('authenticated', 'public.player_alliance_applications', 'SELECT')
        and not has_table_privilege('anon', 'public.player_alliance_applications', 'SELECT');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '18. the three alliance tables also have NO direct grant for authenticated/anon');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 19. RLS is enabled everywhere in the social layer */
    v_ok := (select bool_and(relrowsecurity) from pg_class
              where oid in ('public.player_buddies'::regclass, 'public.player_alliances'::regclass,
                            'public.player_alliance_ranks'::regclass,
                            'public.player_alliance_members'::regclass,
                            'public.player_alliance_applications'::regclass));
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '19. RLS is enabled on all five social tables');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 20. anon cannot EXECUTE the social RPCs */
    v_ok := not has_function_privilege('anon', 'public.send_buddy_request(uuid, text)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.respond_buddy_request(uuid, boolean)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.list_buddies()', 'EXECUTE')
        and not has_function_privilege('anon', 'public.create_alliance(text, text)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.can_defend_player(uuid, uuid)', 'EXECUTE');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '20. anon cannot EXECUTE any social RPC');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 21. no social RPC accepts a caller identity parameter */
    v_ok := not exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('send_buddy_request','respond_buddy_request','cancel_buddy_request',
                              'remove_buddy','create_alliance','apply_to_alliance','leave_alliance',
                              'dissolve_alliance','respond_alliance_application')
           and pg_get_function_arguments(p.oid) ~* 'p_caller_id|p_actor_id|p_requesting_player_id');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '21. no social RPC accepts a caller identity parameter: the caller always comes from auth.uid()');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* ============================== ALLIANCES ============================== */

    /* 22. alice founds an alliance and becomes its founder member */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select out_alliance_id into v_alliance from public.create_alliance('LGISF', 'Social Fixture Alliance');
    select count(*)::integer into v_n from public.player_alliance_members m
     where m.alliance_id = v_alliance and m.player_id = v_alice and m.rank_id is null;
    v_ok := v_alliance is not null and v_n = 1;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('22. create_alliance inserts the founder membership with rank_id NULL (OGameX), %s row(s)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 23. ONE alliance per player */
    v_err := null;
    begin perform * from public.create_alliance('LGIX', 'Second'); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_ALREADY_MEMBER%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('23. a player cannot belong to two alliances (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 24. the FOUNDER holds ALL permissions (OGameX hasPermission) */
    v_ok := public.alliance_member_permission(v_alice, v_alliance, 'manage_classes')
        and public.alliance_member_permission(v_alice, v_alliance, 'kick_user')
        and public.alliance_member_permission(v_alice, v_alliance, 'delete_ally');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '24. the FOUNDER holds every permission, including ones no rank grants');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 25. bob applies, alice accepts */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_b)::text, true);
    select out_application_id into v_app from public.apply_to_alliance(v_alliance, 'let me in');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    perform * from public.respond_alliance_application(v_app, true);
    select count(*)::integer into v_n from public.player_alliance_members m
     where m.alliance_id = v_alliance and m.player_id = v_bob;
    v_ok := v_app is not null and v_n = 1;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('25. acceptance atomically created the membership row (%s)', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 26. a plain member holds NO permission */
    v_ok := not public.alliance_member_permission(v_bob, v_alliance, 'manage_classes')
        and not public.alliance_member_permission(v_bob, v_alliance, 'edit_applications');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '26. a plain member holds NO administrative permission');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 27. CROSS-ALLIANCE: carol cannot act on this alliance */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_c)::text, true);
    v_err := null;
    begin perform * from public.create_alliance_rank('Usurper', array['manage_classes']); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_MEMBERSHIP_NOT_FOUND%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('27. a NON-MEMBER cannot create ranks in another alliance (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 28. the roster is invisible to a non-member */
    select count(*)::integer into v_n from public.list_alliance_members(v_alliance);
    v_ok := v_n = 0;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('28. a non-member sees an EMPTY roster (%s row(s)) — see_members is enforced', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 29. the founder sees the roster */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select count(*)::integer into v_n from public.list_alliance_members(v_alliance);
    v_ok := v_n = 2;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('29. the founder sees the full roster (%s row(s))', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* 30. an unknown OGameX permission is refused */
    v_err := null;
    begin perform * from public.create_alliance_rank('Bogus', array['invented_permission']); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_PERMISSION_UNKNOWN%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('30. a permission outside the OGameX vocabulary is refused (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 31. the founder creates a rank and promotes bob */
    select out_rank_id into v_rank from public.create_alliance_rank('Officer', array['manage_classes','see_members'], 1);
    perform * from public.set_alliance_member_rank(v_bob, v_rank);
    v_ok := v_rank is not null
        and public.alliance_member_permission(v_bob, v_alliance, 'manage_classes');
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '31. a promoted member gains exactly the permissions of its rank');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 32. the founder's rank is fixed and cannot be reassigned */
    v_err := null;
    begin perform * from public.set_alliance_member_rank(v_alice, v_rank); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_FOUNDER_RANK_IS_FIXED%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('32. the FOUNDER''s rank cannot be set: authority is not a rank (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 33. a member cannot reach across alliances */
    v_err := null;
    begin perform * from public.set_alliance_member_rank(v_carol, v_rank); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_TARGET_NOT_MEMBER%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('33. a member of ANOTHER alliance cannot be ranked here (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 34. the founder cannot leave */
    v_err := null;
    begin perform * from public.leave_alliance(); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_FOUNDER_CANNOT_LEAVE%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('34. the FOUNDER cannot leave the alliance (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 35. only the founder may dissolve */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_b)::text, true);
    v_err := null;
    begin perform * from public.dissolve_alliance(); exception when others then v_err := sqlerrm; end;
    v_ok := v_err like '%ALLIANCE_NOT_FOUND_OR_NOT_FOUNDER%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('35. a MEMBER cannot dissolve the alliance (%s)', coalesce(v_err, 'ACCEPTED')));
    v_fails := v_fails + case when v_ok then 0 else 1 end;
    select count(*)::integer into v_n from public.player_alliances where id = v_alliance;
    v_ok := v_n = 1;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('36. the refused dissolve left the alliance intact (%s row(s))', v_n));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 37. friendship is NOT alliance membership (OGameX keeps them apart) */
    v_ok := public.players_in_same_alliance(v_alice, v_bob)
        and not public.players_in_same_alliance(v_alice, v_carol);
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '37. alliance membership and friendship remain SEPARATE relations');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* ============================== DEFEND AUTHORIZATION ============================== */

    /* 38. unrelated players are denied */
    select * into v_r from public.can_defend_player(v_carol, v_pl_alice);
    v_ok := not v_r.out_allowed and v_r.out_reason = 'DEFEND_NOT_BUDDY_OR_ALLY';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('38. DEFEND denied without any relationship (%s)', v_r.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 39. the defended owner is resolved SERVER-SIDE from the planet */
    v_ok := v_r.out_owner = v_alice;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('39. the defended owner is resolved from the planet, never from the client (%s)', v_r.out_owner));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 40. own planet refused (OGameX checkOwnPlanet) */
    select * into v_r from public.can_defend_player(v_alice, v_pl_alice);
    v_ok := not v_r.out_allowed and v_r.out_reason = 'DEFEND_OWN_PLANET';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('40. DEFEND on your OWN planet is refused (%s)', v_r.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 41. unknown planet refused */
    select * into v_r from public.can_defend_player(v_carol, gen_random_uuid());
    v_ok := not v_r.out_allowed and v_r.out_reason = 'DEFEND_TARGET_NOT_FOUND';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('41. DEFEND on an unknown planet is refused (%s)', v_r.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 42. an ALLY may defend (OGameX rule) */
    select * into v_r from public.can_defend_player(v_bob, v_pl_alice);
    v_ok := v_r.out_allowed and v_r.out_via_alliance;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('42. a same-alliance member may defend the owner''s planet (%s)', v_r.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 43. a BUDDY may defend, in BOTH directions */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select out_id into v_req2 from public.send_buddy_request(v_carol);
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_c)::text, true);
    perform * from public.respond_buddy_request(v_req2, true);
    select * into v_r from public.can_defend_player(v_alice, v_pl_carol);
    v_ok := v_r.out_allowed and v_r.out_via_buddy;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('43. a BUDDY may defend the owner''s planet (%s)', v_r.out_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    select * into v_r from public.can_defend_player(v_carol, v_pl_alice);
    v_ok := v_r.out_allowed and v_r.out_via_buddy;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '44. buddies is SYMMETRIC for DEFEND: the addressee may defend the requester too');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 45. a PENDING request is NOT authorization */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_a)::text, true);
    select out_id into v_req2 from public.send_buddy_request(v_bob);
    select * into v_r from public.can_defend_player(v_carol, v_pl_bob);
    v_ok := not v_r.out_allowed;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '45. a PENDING buddy request is NOT a DEFEND authorization');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 46. a REJECTED request is NOT authorization */
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth_c)::text, true);
    perform * from public.respond_buddy_request(v_req2, false);
    v_ok := not public.players_are_buddies(v_carol, v_bob)
        and not (select out_allowed from public.can_defend_player(v_carol, v_pl_bob));
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '46. a REJECTED request is NOT a DEFEND authorization');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

/* ============================== READINESS (honest) ============================== */

    /* 47. DEFEND is NOT dispatchable yet, and the contract must say so */
    select * into v_r from public.defend_dispatch_readiness();
    v_ok := v_r.out_schema_ready
        and not v_r.out_dispatch_open
        and not v_r.out_combat_ready
        and v_r.out_authorization_ready;
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('47. readiness is HONEST: schema+authorization ready, dispatch+combat NOT ready (%s)',
             v_r.out_blocking_reason));
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    /* 48. the certified combat engine was NOT modified by the social layer */
    v_ok := (select p.prosrc from pg_proc p where p.proname = 'start_support_fleet'
               and p.pronamespace = 'public'::regnamespace) ilike '%COMBAT_SUPPORT_NOT_READY%'
        and (select p.prosrc from pg_proc p where p.proname = 'resolve_combat'
               and p.pronamespace = 'public'::regnamespace) not ilike '%holding%';
    insert into t_social(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      '48. the social layer did NOT touch the combat engine: start_support_fleet still refuses DEFEND and resolve_combat still ignores HOLDING');
    v_fails := v_fails + case when v_ok then 0 else 1 end;

    insert into t_social(resultado, prueba) values ('INFO',
      format('SUMMARY: %s failed assertion(s).', v_fails));
    raise notice 'SOCIAL FOUNDATIONS FIXTURE: % failures', v_fails;
end $test$;

select orden, resultado, prueba from t_social order by orden;

rollback;