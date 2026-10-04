-- ============================================================================================
-- FIX — ship losses must respect `fleet_movement_ships_quantity_chk` (CHECK quantity > 0)
-- ============================================================================================
-- Both settlement paths subtracted a rolled ship loss with
--     UPDATE ... SET quantity = quantity - <loss>  (followed by DELETE ... AND quantity <= 0)
-- so when the rolled loss consumed an ENTIRE stack the UPDATE wrote quantity = 0, violated
-- fleet_movement_ships_quantity_chk and aborted the statement; the DELETE meant to remove the exhausted row could never
-- run.
--
-- 1) settle_moon_destruction_for_battle(uuid) — moon destruction, branch "the moon survived". The body is wrapped in
--    `exception when others ... raise warning`, so the failure was SWALLOWED: no `moon_destruction_attempts` row (no
--    provenance/idempotency), no message for either side, and the attacker KEPT the Deathstars it should have lost.
--    Reproduced LIVE 2026-09-28 (instrumented probes dropped the outcome in 3/6, 3/6 and 1/6 attempts; postgres_logs
--    carries MOON_DESTRUCTION_FAILED from that handler; the case is "moon survived AND every Deathstar lost", 35 % of
--    survived attempts with 1 Deathstar at 5 000 km). Record: docs/systems/README_MOON_ENGINE.md §12.1 (D6).
--
-- 2) resolve_expedition_black_hole(uuid) — expedition black hole: 6/6 reproductions LIVE for the fleet
--    {espionage_probe 1, light_fighter 1} with `new row for relation "fleet_movement_ships" violates check constraint
--    "fleet_movement_ships_quantity_chk"`. Here the error is NOT swallowed: it propagates to
--    `resolve_expedition_arrival` for a deterministic roll, so the expedition cannot resolve. Record:
--    docs/systems/README_FLEET_ENGINE.md.
--
-- Fix (identical shape in both paths): delete the stacks the loss exhausts, then subtract only from the surviving
-- stacks, storing the SAME rolled loss without ever writing `quantity = 0`.
-- No signature, ACL, contract, table, formula or distribution changes; ACLs are preserved by CREATE OR REPLACE and
-- re-verified at the end of this migration.
--
-- LIVE: applied 2026-09-28 as version 20260928121226.
-- Resulting definitions: settle_moon_destruction_for_battle md5 6d1b2c991c2c42488c8a4898983d4734 (was
-- 9007ac2a6adc4e9b19ac7beec4fc0aed) · resolve_expedition_black_hole md5 8db2c06ae768312ca05eda82e422e3a2 (was
-- b9771f6d1527aa78059f7ffe4b2ed8b0).
-- ============================================================================================

do $fix$
declare
    v_src text;
    v_new text;
    v_n integer;
    v_old text;
begin
    /* ---------- 1) moon destruction: subtract only from the surviving Deathstars ---------- */
    v_src := pg_get_functiondef('public.settle_moon_destruction_for_battle(uuid)'::regprocedure);

    if position('fms.quantity > v_lost' in v_src) > 0 then
        raise notice 'FLEET_LOSS_CHECK: moon destruction already patched (no-op)';
    else
        v_n := (length(v_src) - length(replace(v_src, 'set quantity = fms.quantity - v_lost', ''))) / length('set quantity = fms.quantity - v_lost');
        if v_n <> 1 then
            raise exception 'FLEET_LOSS_CHECK: expected exactly 1 Deathstar loss UPDATE in the moon path, found %', v_n;
        end if;

        v_old := 'and fms.quantity <= 0;';
        v_n := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
        if v_n <> 1 then
            raise exception 'FLEET_LOSS_CHECK: expected exactly 1 unreachable DELETE in the moon path, found %', v_n;
        end if;

        -- The WHERE clause is shared with the deathstar-count SELECT, so the replacement is anchored on the unique
        -- `set quantity = ...` line of the loss UPDATE.
        v_new := regexp_replace(v_src,
            '(set quantity = fms\.quantity - v_lost\s+where fms\.fleet_id = v_battle\.fleet_id and fms\.ship_id = ''deathstar'')',
            '\1 and fms.quantity > v_lost', 'g');
        if v_new = v_src then
            raise exception 'FLEET_LOSS_CHECK: the moon UPDATE anchor did not match';
        end if;

        v_src := replace(v_new, 'and fms.quantity <= 0;', 'and fms.quantity <= v_lost;');

        if position('fms.quantity > v_lost' in v_src) = 0
           or position('and fms.quantity <= v_lost;' in v_src) = 0
           or position('fms.quantity <= 0;' in v_src) > 0 then
            raise exception 'FLEET_LOSS_CHECK: moon path patch did not produce the expected definition';
        end if;

        execute v_src;
    end if;

    /* ---------- 2) expedition black hole: same shape ---------- */
    v_src := pg_get_functiondef('public.resolve_expedition_black_hole(uuid)'::regprocedure);

    -- Marker unique to this patch: the legacy source only has `v_ship.quantity>v_loss_qty` inside the IF guard.
    if position('AND quantity>v_loss_qty' in v_src) > 0 then
        raise notice 'FLEET_LOSS_CHECK: black hole already patched (no-op)';
    else
        v_old := 'UPDATE public.fleet_movement_ships SET quantity=quantity-v_loss_qty WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id;DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id AND quantity<=0;';
        if position(v_old in v_src) = 0 then
            raise exception 'FLEET_LOSS_CHECK: black-hole legacy block not found';
        end if;

        v_new := 'DELETE FROM public.fleet_movement_ships WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id AND quantity<=v_loss_qty;UPDATE public.fleet_movement_ships SET quantity=quantity-v_loss_qty WHERE fleet_id=p_fleet_id AND ship_id=v_ship.ship_id AND quantity>v_loss_qty;';
        v_src := replace(v_src, v_old, v_new);

        if position('AND quantity<=v_loss_qty' in v_src) = 0
           or position('AND quantity>v_loss_qty' in v_src) = 0
           or position('AND quantity<=0;' in v_src) > 0 then
            raise exception 'FLEET_LOSS_CHECK: black-hole patch did not produce the expected definition';
        end if;

        execute v_src;
    end if;
end;
$fix$;

-- Post-conditions: no live settlement path may still write `quantity = 0`, and the ACLs must be untouched.
do $verify$
declare
    v_bad text;
begin
    select string_agg(p.proname, ', ') into v_bad
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('settle_moon_destruction_for_battle', 'resolve_expedition_black_hole')
       and (p.prosrc like '%and fms.quantity <= 0;%' or p.prosrc like '%AND quantity<=0;%');
    if v_bad is not null then
        raise exception 'FLEET_LOSS_CHECK: still writing quantity = 0 -> %', v_bad;
    end if;

    if has_function_privilege('authenticated', 'public.settle_moon_destruction_for_battle(uuid)', 'EXECUTE')
       or has_function_privilege('authenticated', 'public.resolve_expedition_black_hole(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.settle_moon_destruction_for_battle(uuid)', 'EXECUTE')
       or has_function_privilege('anon', 'public.resolve_expedition_black_hole(uuid)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.settle_moon_destruction_for_battle(uuid)', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.resolve_expedition_black_hole(uuid)', 'EXECUTE') then
        raise exception 'FLEET_LOSS_CHECK: ACL drift detected after the patch';
    end if;
end;
$verify$;
