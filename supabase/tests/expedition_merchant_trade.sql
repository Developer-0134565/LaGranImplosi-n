-- EXPEDITION MERCHANT TRADE — CLIENT CONTRACT FIXTURE — LA GRAN IMPLOSIÓN
-- ----------------------------------------------------------------------------
-- NOT A MIGRATION. Transactional regression fixture: it always ends in ROLLBACK.
--
-- Contract under test (migration 20260927024948_expedition_merchant_trade_contract):
--   * `get_player_expedition_merchant()` — owner-scoped read of the ACTIVE expedition-merchant offer
--     (`player_expedition_merchants` is closed to the client by the `deny_direct_api_access` policy);
--   * `trade_with_expedition_merchant(p_planet_id, p_sell_resource, p_sell_amount)` — identity from
--     `auth.uid()` → `players.user_id` (never a client-supplied player id), ownership of the body checked,
--     and the whole RULE delegated to the already-LIVE `execute_expedition_merchant_trade` (which stays
--     service_role-only: it must keep serving the AI actor with its own `p_player_id`).
--
-- Why the gap existed: the MERCHANT outcome is weighted in the active universe (`weight_merchant` = 0.4),
-- `resolve_expedition_arrival` → `resolve_expedition_merchant` persisted the offer and the report/message
-- announced it — and nothing could ever consume it: the table was closed to the client and the only trade
-- function had no caller at all.
--
-- Assertions: ACL (authenticated yes, anon never, no PUBLIC, internal function still closed), the exact
-- rates/amounts of a trade, one-trade-per-merchant, per-actor isolation, the storage clamp (never
-- overflowing), and that every refusal leaves resources, the offer and the active flag untouched.
--
-- LIMITATION: single-session harness. Concurrency is not executed (declared, not faked); the merchant row is
-- locked `FOR UPDATE` inside the delegated function, which is what makes a double trade serialize.

begin;

drop table if exists t_merchant_results;
create temp table t_merchant_results(orden serial, resultado text, prueba text);

do $test$
declare
    v_auth uuid;
    v_player uuid;
    v_planet uuid;
    v_foreign_player uuid;
    v_foreign_planet uuid;
    v_other_auth uuid;
    v_ok boolean;
    v_blocked boolean;
    v_err text;
    v_has boolean;
    v_resource text;
    v_mr numeric; v_cr numeric; v_dr numeric;
    v_sold numeric; v_bought numeric; v_bought_resource text; v_remaining boolean;
    v_mb numeric; v_cb numeric; v_db numeric;
    v_ma numeric; v_ca numeric; v_da numeric;
    v_capm numeric; v_capc numeric; v_capd numeric;
    v_base numeric;
    v_rows integer;
    v_auth_exec boolean;
    v_anon_exec boolean;
    v_internal_exec boolean;
    v_public boolean;
    v_fail integer := 0;
begin
    select pl.id, pl.user_id into v_player, v_auth
      from public.players pl where pl.user_id is not null
     order by pl.created_at, pl.id limit 1;

    select p.id into v_planet
      from public.planets p
     where p.player_id = v_player and not p.is_destroyed
     order by p.created_at, p.id limit 1;

    select pl.id, p.id into v_foreign_player, v_foreign_planet
      from public.planets p join public.players pl on pl.id = p.player_id
     where not p.is_destroyed and pl.id <> v_player
     order by p.created_at, p.id limit 1;

    if v_player is null or v_planet is null or v_foreign_player is null or v_foreign_planet is null then
        raise exception 'TEST_ABORT: an auth-linked player with a planet and a foreign planet are required';
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* A synthetic authenticated identity that owns nothing (ownership gate from the caller side). */
    v_other_auth := gen_random_uuid();

    /* Isolate: no buildings (zero production, so every resource delta is exact) and no merchant rows. */
    delete from public.planet_buildings where planet_id = v_planet;
    delete from public.building_queue where planet_id = v_planet;
    delete from public.research_queue where player_id = v_player;
    delete from public.player_expedition_merchants where player_id in (v_player, v_foreign_player);

    /* Baseline DERIVED from the storage contract (never hardcoded): the settlement inside the trade is
       authoritative and a value ABOVE the capacity would be clamped, breaking exact deltas. */
    select s.metal_capacity, s.crystal_capacity, s.deuterium_capacity
      into v_capm, v_capc, v_capd
      from public.calculate_planet_storage(v_planet) s;
    v_base := greatest(1, floor(least(v_capm, v_capc, v_capd) / 100));

    insert into public.planet_resources(planet_id, metal, crystal, deuterium, energy, last_calculated_at)
    values (v_planet, v_base, v_base, v_base, 0, now())
    on conflict (planet_id) do update
       set metal = excluded.metal, crystal = excluded.crystal, deuterium = excluded.deuterium,
           last_calculated_at = excluded.last_calculated_at;

    /* ---------------------- 1. ACL Y FORMA DEL CONTRATO */
    select has_function_privilege('authenticated', 'public.get_player_expedition_merchant()', 'EXECUTE')
       and has_function_privilege('authenticated', 'public.trade_with_expedition_merchant(uuid, text, numeric)', 'EXECUTE')
      into v_auth_exec;
    select has_function_privilege('anon', 'public.get_player_expedition_merchant()', 'EXECUTE')
        or has_function_privilege('anon', 'public.trade_with_expedition_merchant(uuid, text, numeric)', 'EXECUTE')
      into v_anon_exec;
    select has_function_privilege('authenticated', 'public.execute_expedition_merchant_trade(uuid, uuid, text, numeric)', 'EXECUTE')
      into v_internal_exec;
    select exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('get_player_expedition_merchant', 'trade_with_expedition_merchant')
           and exists (select 1 from unnest(p.proacl) a where a::text like '=%')
    ) into v_public;

    v_ok := v_auth_exec and not v_anon_exec and not v_internal_exec and not v_public;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('1. authenticated EXECUTE=%s, anon=%s, PUBLIC grant=%s; the delegated rule stays service_role-only (%s)',
             v_auth_exec, v_anon_exec, v_public, v_internal_exec));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 2. ACTOR SIN SESIÓN: rechazo y lectura vacía */
    perform set_config('request.jwt.claims', '{}', true);

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select count(*)::integer into v_rows from public.get_player_expedition_merchant();

    v_ok := v_blocked and v_err = 'Authentication required' and v_rows = 0;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('2. without a session the trade is refused [%s / %s] and the read returns %s row(s)',
             v_blocked, v_err, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 3. SIN OFERTA ACTIVA: rechazo y CERO mutación */
    select metal, crystal into v_mb, v_cb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and position('No active merchant for player' in v_err) > 0
        and v_ma = v_mb and v_ca = v_cb;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('3. no active offer: the trade is refused [%s / %s], resources untouched [%s/%s]',
             v_blocked, v_err, v_ma - v_mb, v_ca - v_cb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 4. PROPIEDAD: una oferta activa NO autoriza a tocar un cuerpo ajeno */
    insert into public.player_expedition_merchants(player_id, resource, metal_rate, crystal_rate, deuterium_rate, source, active)
    values (v_player, 'METAL', 3, 2, 1, 'EXPEDITION', true)
    on conflict (player_id) do update
       set resource = excluded.resource, metal_rate = excluded.metal_rate, crystal_rate = excluded.crystal_rate,
           deuterium_rate = excluded.deuterium_rate, source = 'EXPEDITION', active = true, updated_at = now();

    select metal, crystal into v_mb, v_cb from public.planet_resources where planet_id = v_planet;
    select metal into v_fb from public.planet_resources where planet_id = v_foreign_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_foreign_planet, 'CRYSTAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    select metal into v_mr from public.planet_resources where planet_id = v_foreign_planet;

    v_ok := v_blocked and v_err = 'PLANET_NOT_FOUND_OR_NOT_OWNED'
        and v_ma = v_mb and v_ca = v_cb and v_mr = v_fb and v_mr = v_fb;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('4. a foreign body is refused [%s / %s]; own and foreign resources untouched [%s/%s]',
             v_blocked, v_err, v_ma - v_mb, v_ca - v_cb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* Y con una identidad autenticada sintética que no posee nada */
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_auth)::text, true);
    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    select count(*)::integer into v_rows from public.get_player_expedition_merchant();
    v_ok := v_blocked and v_err = 'PLANET_NOT_FOUND_OR_NOT_OWNED' and v_rows = 0;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('5. an authenticated stranger owns nothing: trade refused [%s / %s] and the read leaks %s row(s)',
             v_blocked, v_err, v_rows));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);

    /* ---------------------- 6. LECTURA owner-scoped de la oferta activa */
    select has_merchant, offered_resource, metal_rate, crystal_rate, deuterium_rate
      into v_has, v_resource, v_mr, v_cr, v_dr
      from public.get_player_expedition_merchant();

    v_ok := v_has and v_resource = 'METAL' and v_mr = 3 and v_cr = 2 and v_dr = 1;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('6. the owner reads the active offer [has=%s, entrega %s, tasas %s/%s/%s]',
             v_has, v_resource, v_mr, v_cr, v_dr));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 7. COMERCIO REAL: 100 cristal → 150 metal (metal_rate/crystal_rate) */
    select metal, crystal, deuterium into v_mb, v_cb, v_db from public.planet_resources where planet_id = v_planet;

    select r.sold, r.bought, r.bought_resource, r.remaining_merchant
      into v_sold, v_bought, v_bought_resource, v_remaining
      from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 100) r;

    select metal, crystal, deuterium into v_ma, v_ca, v_da from public.planet_resources where planet_id = v_planet;
    select active into v_has from public.player_expedition_merchants where player_id = v_player;

    v_ok := v_sold = 100 and v_bought = 150 and v_bought_resource = 'METAL' and not v_remaining and not v_has
        and v_ma = v_mb + 150 and v_ca = v_cb - 100 and v_da = v_db;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('7. trade executed [vendido %s, recibido %s %s, comerciante restante=%s, oferta activa=%s] y recursos %s/%s/%s',
             v_sold, v_bought, v_bought_resource, v_remaining, v_has, v_ma - v_mb, v_ca - v_cb, v_da - v_db));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 8. UN SOLO COMERCIO: la segunda llamada se rechaza sin doble premio */
    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    insert into t_merchant_results(resultado, prueba) values (case when v_blocked then 'PASS' else 'FAIL' end,
      format('8. a second trade is refused [%s / %s]; resources now %s/%s',
             v_blocked, v_err, v_ma - v_mb, v_ca - v_cb));
    v_fail := v_fail + case when (v_blocked and position('No active merchant for player' in v_err) > 0) then 0 else 1 end;

    /* ---------------------- 9. TRAS EL COMERCIO LA LECTURA YA NO OFRECE NADA */
    select has_merchant into v_has from public.get_player_expedition_merchant();
    insert into t_merchant_results(resultado, prueba) values (case when not v_has then 'PASS' else 'FAIL' end,
      format('9. after the trade the read reports has_merchant=%s', v_has));
    v_fail := v_fail + case when not v_has then 0 else 1 end;

    /* ---------------------- 10. REGLA INTERNA: no se puede pagar con el recurso que el comerciante entrega */
    insert into public.player_expedition_merchants(player_id, resource, metal_rate, crystal_rate, deuterium_rate, source, active)
    values (v_player, 'METAL', 3, 2, 1, 'EXPEDITION', true)
    on conflict (player_id) do update set active = true, updated_at = now();

    select metal, crystal into v_mb, v_cb from public.planet_resources where planet_id = v_planet;
    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'METAL', 100);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    select active into v_has from public.player_expedition_merchants where player_id = v_player;

    v_ok := v_blocked and position('Merchant buys' in v_err) > 0
        and v_ma = v_mb and v_ca = v_cb and v_has;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('10. paying with the offered resource is refused by the RULE [%s / %s], offer still active=%s',
             v_blocked, v_err, v_has));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 11. RECURSOS INSUFICIENTES: rechazo y CERO mutación */
    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 1000000000);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and position('Insufficient crystal' in v_err) > 0 and v_ma = v_mb and v_ca = v_cb;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('11. insufficient resources refused [%s / %s], resources untouched [%s/%s]',
             v_blocked, v_err, v_ma - v_mb, v_ca - v_cb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 12. RECORTE POR ALMACÉN: nunca se desborda la capacidad */
    update public.planet_resources
       set metal = v_capm - 10, crystal = v_base, updated_at = now()
     where planet_id = v_planet;

    select r.sold, r.bought into v_sold, v_bought
      from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 1000) r;

    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    v_ok := v_bought = 10 and v_sold = 20 and v_ma = v_capm and v_ca = v_base - 20;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('12. storage clamp [pedido 1000 cristal -> vendido %s, recibido %s; metal %s / capacidad %s]',
             v_sold, v_bought, v_ma, v_capm));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 13. AISLAMIENTO POR ACTOR: el comerciante de otro no es mío */
    delete from public.player_expedition_merchants where player_id = v_player;
    insert into public.player_expedition_merchants(player_id, resource, metal_rate, crystal_rate, deuterium_rate, source, active)
    values (v_foreign_player, 'METAL', 3, 2, 1, 'EXPEDITION', true)
    on conflict (player_id) do update set active = true, updated_at = now();

    select metal, crystal into v_mb, v_cb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 10);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;

    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    select active into v_has from public.player_expedition_merchants where player_id = v_foreign_player;
    select has_merchant into v_remaining from public.get_player_expedition_merchant();

    v_ok := v_blocked and position('No active merchant for player' in v_err) > 0
        and v_ma = v_mb and v_ca = v_cb and v_has and not v_remaining;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('13. a foreign offer is not usable [%s / %s]; his offer stays active=%s and my read says has_merchant=%s',
             v_blocked, v_err, v_has, v_remaining));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    /* ---------------------- 14. ARGUMENTOS INVÁLIDOS: validación de la regla interna, sin mutación */
    select metal, crystal into v_mb, v_cb from public.planet_resources where planet_id = v_planet;

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'CRYSTAL', 0);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    v_ok := v_blocked and position('Sell amount must be positive' in v_err) > 0;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14a. a non-positive amount is refused [%s / %s]', v_blocked, v_err));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    v_blocked := false; v_err := null;
    begin
        perform * from public.trade_with_expedition_merchant(v_planet, 'PLASMA', 10);
    exception when others then v_blocked := true; v_err := sqlerrm;
    end;
    select metal, crystal into v_ma, v_ca from public.planet_resources where planet_id = v_planet;
    v_ok := v_blocked and position('Invalid sell resource' in v_err) > 0 and v_ma = v_mb and v_ca = v_cb;
    insert into t_merchant_results(resultado, prueba) values (case when v_ok then 'PASS' else 'FAIL' end,
      format('14b. an unknown resource is refused [%s / %s], resources untouched [%s/%s]',
             v_blocked, v_err, v_ma - v_mb, v_ca - v_cb));
    v_fail := v_fail + case when v_ok then 0 else 1 end;

    insert into t_merchant_results(resultado, prueba) values ('INFO',
      'LIMITATION: single-session harness; concurrency is not executed. The delegated rule locks the merchant row FOR UPDATE, which is what serializes a double trade.');
    insert into t_merchant_results(resultado, prueba) values ('INFO',
      'SCOPE: only the expedition variant of the merchant is exposed (GainMerchantTrade). The general merchant, the shop and the premium economy (Dark Matter spending) remain out of scope and untouched.');

    if v_fail > 0 then
        raise exception 'EXPEDITION MERCHANT TRADE FIXTURE: % failed assertion(s)', v_fail;
    end if;
end;
$test$;

select orden, resultado, prueba from t_merchant_results order by orden;

drop table if exists t_merchant_results;

ROLLBACK;


