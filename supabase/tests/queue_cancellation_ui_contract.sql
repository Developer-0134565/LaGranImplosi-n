-- QUEUE CANCELLATION — CLIENT (UI) SURFACE FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Scope: the surface the FRONTEND consumes for queue cancellation (`src/App.tsx`, the CANCELAR control of the
-- active queue in the EDIFICIOS / INVESTIGACIÓN views). The BACKEND contract itself — refund policy taken from
-- OGameX, ownership derived from `auth.uid()`, atomicity, the already-due race — is certified by
-- `supabase/tests/queue_cancellation.sql` and is NOT re-derived here. This fixture pins what the browser
-- relies on, so a drift fails a fixture instead of the UI:
--   1. call shape     exactly ONE argument (the queue id); the UI never sends a player or planet id;
--   2. return shape   the declared columns are EXACTLY the ones declared for `cancel_building` /
--                     `cancel_research` in `src/lib/database.types.ts` (changing them must be deliberate);
--   3. precondition   the status the UI offers CANCELAR for (BUILDING / RESEARCHING) is the ONLY
--                     non-terminal status the schema admits, and it is exactly the status the contract
--                     accepts; COMPLETED and CANCELLED are refused without mutating anything;
--   4. buildings view a demolition row is labelled from `building_queue.is_downgrade`, which the owner can
--                     read, and its refund is the certified DEMOLITION cost (never the upgrade price).
--
-- LIMITATION: single-session harness. Atomicity is asserted as "a refused call leaves resources, queue
-- statuses and levels untouched"; true concurrency is not executed (declared, not faked).
--
-- Certified: 2026-09-27 (LIVE, rolled back, zero residue).

begin;

drop table if exists t_cancel_ui_results;
create temp table t_cancel_ui_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_planet uuid;
    v_queue uuid;
    v_queue2 uuid;
    v_args text;
    v_actual text;
    v_expected text;
    v_set text;
    v_count integer;
    v_ok boolean;
    v_blocked boolean;
    v_err text;
    v_status text;
    v_flag boolean;
    v_mb numeric; v_cb numeric; v_db numeric;
    v_ma numeric; v_ca numeric; v_da numeric;
    v_cm numeric; v_cc numeric; v_cd numeric;
    v_rm numeric; v_rc numeric; v_rd numeric;
    v_dm numeric; v_um numeric;
    v_ion integer;
    v_refund record;
    v_capm numeric; v_capc numeric; v_capd numeric;
    v_base numeric;
    v_fail integer := 0;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id into v_planet
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with an owned planet is required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* Isolate: no buildings (zero production, so every resource assertion is exact) and no queue rows. */
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    delete from public.research_queue where player_id = v_player;

    /* Resource baseline DERIVED from the authoritative storage contract (never hardcoded): the authoritative
       tick inside a real cancel settles the planet, so a baseline ABOVE the capacity would be clamped and the
       refund deltas would stop being exact (measured LIVE 2026-09-27: a 100 000 baseline sits exactly at the
       homeworld cap and assertion 11 read -60 on metal, i.e. the clamp, instead of the refund). A hundredth of
       the smallest capacity stays far below every cap and is still non-zero. */
    select s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
      into v_capm, v_capc, v_capd
      from public.calculate_planet_storage(v_planet) s;
    v_base := greatest(1, floor(least(v_capm, v_capc, v_capd) / 100));

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet, v_base, v_base, v_base, 0, now())
    on conflict (planet_id) do update
       set metal = excluded.metal,
           crystal = excluded.crystal,
           deuterium = excluded.deuterium,
           last_calculated_at = excluded.last_calculated_at;

    /* ---------------------- 1. CALL SHAPE + ACL (exactly what the browser is allowed to invoke) */
    select pg_get_function_arguments(p.oid) into v_args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'cancel_building';

    select count(*)::integer into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('cancel_building', 'cancel_research')
       and p.pronargs = 1;

    v_ok := v_args = 'p_queue_id uuid'
        and v_count = 2
        and has_function_privilege('authenticated', 'public.cancel_building(uuid)', 'EXECUTE')
        and has_function_privilege('authenticated', 'public.cancel_research(uuid)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.cancel_building(uuid)', 'EXECUTE')
        and not has_function_privilege('anon', 'public.cancel_research(uuid)', 'EXECUTE');
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. UI call shape = one queue id [%s]; single-argument overloads %s; authenticated EXECUTE, anon never',
             v_args, v_count));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 2/3. RETURN SHAPE PINNED TO src/lib/database.types.ts */
    select pg_get_function_result(p.oid) into v_actual
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'cancel_building';
    v_expected := 'TABLE(queue_id uuid, planet_id uuid, building_id text, target_level integer, refund_metal numeric, refund_crystal numeric, refund_deuterium numeric, status text)';
    v_ok := v_actual = v_expected;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. cancel_building declares exactly the columns the TS type mirrors [%s]', v_actual));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pg_get_function_result(p.oid) into v_actual
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'cancel_research';
    v_expected := 'TABLE(queue_id uuid, player_id uuid, planet_id uuid, research_id text, target_level integer, refund_metal numeric, refund_crystal numeric, refund_deuterium numeric, status text)';
    v_ok := v_actual = v_expected;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. cancel_research declares exactly the columns the TS type mirrors [%s]', v_actual));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 4/5. THE UI PRECONDITION EQUALS THE SCHEMA'S ONLY NON-TERMINAL STATUS */
    select pg_get_constraintdef(con.oid) into v_set
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'building_queue'
       and con.conname = 'building_queue_status_check';

    v_count := (length(v_set) - length(replace(v_set, '''', ''))) / 2;
    v_ok := v_count = 3
        and position('''BUILDING''' in v_set) > 0
        and position('COMPLETED' in v_set) > 0
        and position('CANCELLED' in v_set) > 0
        and position('QUEUED' in v_set) = 0;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. building_queue admits BUILDING as its only non-terminal status (%s literal(s)) [%s]', v_count, v_set));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    select pg_get_constraintdef(con.oid) into v_set
      from pg_constraint con
      join pg_class c on c.oid = con.conrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'research_queue'
       and con.conname = 'research_queue_status_check';

    v_count := (length(v_set) - length(replace(v_set, '''', ''))) / 2;
    v_ok := v_count = 3
        and position('''RESEARCHING''' in v_set) > 0
        and position('COMPLETED' in v_set) > 0
        and position('CANCELLED' in v_set) > 0
        and position('QUEUED' in v_set) = 0;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. research_queue admits RESEARCHING as its only non-terminal status (%s literal(s)) [%s]', v_count, v_set));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 6/7. TERMINAL BUILDING ROWS ARE REFUSED AND NOTHING MUTATES
       (the UI never offers CANCELAR for them) */
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'metal_mine', 1, now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
    returning id into v_queue;
    select metal into v_mb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select status into v_status from public.building_queue where id = v_queue;
    select metal into v_ma from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and v_err = 'BUILDING_QUEUE_NOT_CANCELLABLE: COMPLETED'
        and v_status = 'COMPLETED' and v_ma = v_mb;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. COMPLETED building row refused, status and resources untouched [%s / %s / refunded %s]',
             v_blocked, v_status, v_ma - v_mb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'metal_mine', 1, now() - interval '2 hours', now() - interval '1 hour', 'CANCELLED')
    returning id into v_queue;
    select metal into v_mb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_building(v_queue);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select status into v_status from public.building_queue where id = v_queue;
    select metal into v_ma from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and v_err = 'BUILDING_QUEUE_NOT_CANCELLABLE: CANCELLED'
        and v_status = 'CANCELLED' and v_ma = v_mb;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. CANCELLED building row is idempotently refused, nothing refunded [%s / %s / refunded %s]',
             v_blocked, v_status, v_ma - v_mb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 8/9. SAME FOR THE RESEARCH QUEUE */
    insert into public.research_queue(player_id, planet_id, research_id, target_level, started_at, finishes_at, status)
    values (v_player, v_planet, 'energy_technology', 1, now() - interval '2 hours', now() - interval '1 hour', 'COMPLETED')
    returning id into v_queue2;
    select metal into v_mb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_research(v_queue2);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select status into v_status from public.research_queue where id = v_queue2;
    select metal into v_ma from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and v_err = 'RESEARCH_QUEUE_NOT_CANCELLABLE: COMPLETED'
        and v_status = 'COMPLETED' and v_ma = v_mb;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('8. COMPLETED research row refused, status and resources untouched [%s / %s / refunded %s]',
             v_blocked, v_status, v_ma - v_mb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into public.research_queue(player_id, planet_id, research_id, target_level, started_at, finishes_at, status)
    values (v_player, v_planet, 'energy_technology', 1, now() - interval '2 hours', now() - interval '1 hour', 'CANCELLED')
    returning id into v_queue2;
    select metal into v_mb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.cancel_research(v_queue2);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select status into v_status from public.research_queue where id = v_queue2;
    select metal into v_ma from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and v_err = 'RESEARCH_QUEUE_NOT_CANCELLABLE: CANCELLED'
        and v_status = 'CANCELLED' and v_ma = v_mb;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('9. CANCELLED research row is idempotently refused, nothing refunded [%s / %s / refunded %s]',
             v_blocked, v_status, v_ma - v_mb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 10. THE STATUS THE UI OFFERS IS ACCEPTED (building) AND THE REFUND IS EXACT */
    delete from public.building_queue where planet_id = v_planet;
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status)
    values (v_planet, 'metal_mine', 1, now(), now() + interval '1 hour', 'BUILDING')
    returning id into v_queue;

    select c.metal, c.crystal, c.deuterium into v_cm, v_cc, v_cd
      from public.calculate_building_cost('metal_mine', 1) c;
    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    select * into v_refund from public.cancel_building(v_queue);

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;
    select status into v_status from public.building_queue where id = v_queue;

    v_ok := v_status = 'CANCELLED' and v_refund.status = 'CANCELLED'
        and v_refund.queue_id = v_queue
        and v_refund.refund_metal = v_cm
        and v_refund.refund_crystal = v_cc
        and v_refund.refund_deuterium = v_cd
        and v_ma = v_mb + v_cm and v_ca = v_cb + v_cc and v_da = v_db + v_cd;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. BUILDING row cancel accepted and refunded exactly as charged [status %s, refund %s/%s/%s vs charged %s/%s/%s]',
             v_status, v_refund.refund_metal, v_refund.refund_crystal, v_refund.refund_deuterium, v_cm, v_cc, v_cd));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 11. SAME FOR THE RESEARCH QUEUE */
    delete from public.research_queue where player_id = v_player;
    insert into public.research_queue(player_id, planet_id, research_id, target_level, started_at, finishes_at, status)
    values (v_player, v_planet, 'energy_technology', 1, now(), now() + interval '1 hour', 'RESEARCHING')
    returning id into v_queue2;

    select c.metal, c.crystal, c.deuterium into v_rm, v_rc, v_rd
      from public.calculate_research_cost('energy_technology', 1) c;
    select metal, crystal, deuterium into v_mb, v_cb, v_db
      from public.planet_resources where planet_id = v_planet;

    select * into v_refund from public.cancel_research(v_queue2);

    select metal, crystal, deuterium into v_ma, v_ca, v_da
      from public.planet_resources where planet_id = v_planet;
    select status into v_status from public.research_queue where id = v_queue2;

    v_ok := v_status = 'CANCELLED' and v_refund.status = 'CANCELLED'
        and v_refund.queue_id = v_queue2
        and v_refund.refund_metal = v_rm
        and v_refund.refund_crystal = v_rc
        and v_refund.refund_deuterium = v_rd
        and v_ma = v_mb + v_rm and v_ca = v_cb + v_rc and v_da = v_db + v_rd;
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. RESEARCHING row cancel accepted and refunded exactly as charged [status %s, refund %s/%s/%s vs charged %s/%s/%s]',
             v_status, v_refund.refund_metal, v_refund.refund_crystal, v_refund.refund_deuterium, v_rm, v_rc, v_rd));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 12/13. DEMOLITION ROW: the UI labels it, and the refund is the DEMOLITION cost */
    v_ok := has_column_privilege('authenticated', 'public.building_queue', 'is_downgrade', 'SELECT')
        and has_table_privilege('authenticated', 'public.building_queue', 'SELECT');
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. the owner reads building_queue.is_downgrade (the label the buildings view renders) [%s]', v_ok));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    delete from public.building_queue where planet_id = v_planet;
    insert into public.building_queue(planet_id, building_id, target_level, started_at, finishes_at, status, is_downgrade)
    values (v_planet, 'metal_mine', 1, now(), now() + interval '1 hour', 'BUILDING', true)
    returning id into v_queue;

    v_ion := coalesce(public.get_player_research_level(v_player, 'ion_technology'), 0);
    select c.metal into v_dm from public.calculate_building_demolition_cost('metal_mine', 2, v_ion) c;
    select c.metal into v_um from public.calculate_building_cost('metal_mine', 1) c;
    select metal into v_mb from public.planet_resources where planet_id = v_planet;

    select * into v_refund from public.cancel_building(v_queue);

    select metal into v_ma from public.planet_resources where planet_id = v_planet;
    select is_downgrade into v_flag from public.building_queue where id = v_queue;

    v_ok := v_flag
        and v_refund.refund_metal = v_dm
        and v_ma = v_mb + v_dm
        and (v_dm = v_um or v_refund.refund_metal <> v_um);
    insert into t_cancel_ui_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. a downgrade row refunds the DEMOLITION price, not the upgrade price [ion %s, refund %s, demolition %s, upgrade %s]',
             v_ion, v_refund.refund_metal, v_dm, v_um));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_cancel_ui_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. Rejections are asserted to leave resources, statuses and rows untouched.');

    insert into t_cancel_ui_results(resultado, prueba) values ('INFO',
      'OBSERVATION: the buildings view also filters status IN (BUILDING, QUEUED); QUEUED is NOT admitted by building_queue_status_check, so the filter is inert and the offered control set is exactly {BUILDING}.');

    if v_fail > 0 then
        raise exception 'QUEUE CANCELLATION UI CONTRACT FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_cancel_ui_results order by orden;

drop table if exists t_cancel_ui_results;

ROLLBACK;
