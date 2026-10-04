-- RECYCLING DECIMAL RESIDUE — a fully harvested debris field stayed "recyclable" because of
-- numeric division dust.  FORWARD-ONLY. NOT APPLIED TO LIVE by this mission.
-- ---------------------------------------------------------------------------------------------
-- THE DEFECT (measured on LIVE 2026-10-01, pure SELECT probes, zero writes)
--   `collect_debris` splits a harvest proportionally:
--
--       v_remaining_capacity := LEAST(v_capacity, v_total_debris);
--       v_metal_collected   := LEAST(v_remaining_capacity * (v_debris_metal   / v_total_debris), v_debris_metal);
--       v_crystal_collected := LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal);
--
--   `debris_fields.metal` / `.crystal` are **unconstrained `numeric`** (no declared precision or
--   scale); every LIVE row happens to carry **scale 20**. PostgreSQL numeric DIVISION keeps only
--   `select_div_scale` significant digits (default 16, raised to at least the operands' display
--   scale), so `crystal / total` is TRUNCATED. Multiplying the truncated ratio back by the
--   capacity does not reproduce the original amount, and the shortfall is left in the field.
--
--   Reproduced on the audit scenario (metal 40000 / crystal 20000, capacity 60000 — a full drain):
--       20000/60000      = 0.33333333333333333333      (20 decimals, truncated)
--       60000 * that     = 19999.9999999999999998      (scale 20)
--       20000 - that     = dust                        (positive: the row survives)
--
--   `2e-17` IS **NOT** A UNIVERSAL THRESHOLD — measured, not assumed. Across 113 212 simulated
--   full drains with totals up to 3.9e8:
--       113 153 of them (99.95 %) left a residue;  worst |residue| = **1.87002e-12**
--   The dust is linear in the field total (dust ~= total x 10^-20 at the stored scale of 20), so
--   any absolute constant must be justified against the total range, not picked at random.
--
--   Consequence: `UPDATE ... SET crystal = GREATEST(0, d.crystal - v_crystal_collected)` stored a
--   positive value, so `DELETE ... WHERE metal <= 0 AND crystal <= 0` never fired, the row
--   survived, and `get_recyclable_debris_status()` answered `available = true` for a field with
--   nothing in it. A recycler dispatched there collected ~1e-16 and returned (that is no longer
--   fatal: `20261001060000` made an exhausted target return home instead of stalling).
-- THE FIX (two call sites, one mission)
--   1. `collect_debris` — remove the dust AT THE SOURCE. When the fleet can drain the field
--      (`v_remaining_capacity >= v_total_debris`) the correct answer in exact arithmetic is
--      "take everything", so it now takes everything VERBATIM, with no division at all:
--
--          v_metal_collected   := CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_metal
--                                        ELSE LEAST(v_remaining_capacity * (v_debris_metal   / v_total_debris), v_debris_metal)   END;
--          v_crystal_collected := CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_crystal
--                                        ELSE LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal) END;
--
--      The PARTIAL-harvest branch is the ORIGINAL expression, character for character. Verified
--      over 437 211 simulated partial harvests: **0 rows differ**, maximum difference exactly 0.
--      So the proportional rule, the capacity bound and the LEAST clamps are all untouched; the
--      only change is that a case whose exact answer was already "everything" stops being
--      evaluated through a lossy division.
--
--      Proof of the full-drain branch (113 212 cases, totals up to 3.9e8):
--          OLD -> 113 153 non-zero residues, max |residue| 1.87002e-12
--          NEW ->     0 non-zero residues, max |residue| 0, and
--                   metal_collected + crystal_collected = total EXACTLY in every case.
--      Conservation is exact, not approximated.
--
--   2. `get_recyclable_debris_status()` — a read-side guard for rows produced BEFORE this fix.
--      The predicate becomes `> 1e-9` instead of `> 0`.
--
-- WHY 1e-9 IS SAFE (derived from the real types and the measured behaviour, not guessed)
--   * Above the dust: the dust bound is `total x 10^-20`. 1e-9 therefore dominates the dust for
--     any field total up to **1e11** — about 500 000x the largest field that exists in LIVE today
--     (196 300). Measured worst case is 1.87e-12, so the margin is ~535x at that scale.
--   * Below any real amount: debris is generated from destroyed ship resources at
--     `fleet_debris_percentage = 30`, and the cheapest cargo ship in the catalogue has
--     `cargo_capacity = 5000`. The smallest non-zero debris value observed in LIVE is **300**. A
--     value in (0, 1e-9] therefore cannot be a resource amount — it can only be division dust.
--   * The constant is a literal (no new function, no new ACL surface) and the postconditions assert
--     that the predicate carries it, so the two cannot drift apart unnoticed.
--
-- NOT CHANGED
--   * `collect_debris`: capacity, the proportional split, the LEAST clamps, the GREATEST(0, ...)
--     clamps, the DELETE condition, the RETURN QUERY payload, signature, volatility, SECURITY and
--     `search_path`.
--   * `calculate_recycler_capacity`, `can_recycle_debris` (a dead helper with ZERO callers in the
--     database — deliberately left alone), `start_fleet_mixed` and its target selection.
--   * The `20261001060000` exhausted-field fix and the whole RECYCLE branch of
--     `process_fleet_movements`: untouched.
--   * Frontend: nothing. `get_recyclable_debris_status` keeps its signature, volatility, SECURITY
--     and ACL (authenticated + service_role, never anon).
--
-- EDIT METHOD
--   Anchored text splice over the COMPLETE pg_get_functiondef output, the same technique as
--   20261001010000 / 20261001030000 / 20261001040000 / 20261001060000 / 20261001070000. Each
--   anchor is asserted to occur exactly ONCE before the splice.
do $residue$
declare
    v_src text; v_def text; v_n integer;
begin
    /* ===================== 1. collect_debris — exact full drain ===================== */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'RESIDUE: collect_debris not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        'v_remaining_capacity := LEAST\(v_capacity, v_total_debris\);', 'g');
    if v_n <> 1 then
        raise exception 'RESIDUE: collect_debris anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def,
        '    v_remaining_capacity := LEAST(v_capacity, v_total_debris);'||chr(10)
     || '    v_metal_collected := LEAST(v_remaining_capacity * (v_debris_metal / v_total_debris), v_debris_metal);'||chr(10)
     || '    v_crystal_collected := LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal);',

        '    v_remaining_capacity := LEAST(v_capacity, v_total_debris);'||chr(10)
     || '    -- FIX 2026-10-02: see the header. When the fleet can drain the field the exact answer is'||chr(10)
     || '    -- "take everything"; evaluating that through a proportional division truncated the ratio'||chr(10)
     || '    -- at the stored numeric scale and left division dust behind (measured up to 1.87e-12,'||chr(10)
     || '    -- non-zero in 99.95%% of 113 212 simulated full drains), which kept the row alive and made'||chr(10)
     || '    -- get_recyclable_debris_status() answer available=true for an empty field. The PARTIAL'||chr(10)
     || '    -- branch below is the ORIGINAL expression, character for character: the proportional'||chr(10)
     || '    -- rule, the capacity bound and the LEAST clamps are untouched.'||chr(10)
     || '    v_metal_collected := CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_metal'||chr(10)
     || '                             ELSE LEAST(v_remaining_capacity * (v_debris_metal / v_total_debris), v_debris_metal)'||chr(10)
     || '                        END;'||chr(10)
     || '    v_crystal_collected := CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_crystal'||chr(10)
     || '                               ELSE LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal)'||chr(10)
     || '                          END;');

    execute v_def;

    /* =========== 2. get_recyclable_debris_status — read-side epsilon guard =========== */
    select p.prosrc into v_src from pg_proc p
     where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace;
    if v_src is null then raise exception 'RESIDUE: get_recyclable_debris_status not found'; end if;

    select count(*) into v_n from regexp_matches(v_src,
        '\(d\.metal > 0 or d\.crystal > 0\);', 'g');
    if v_n <> 1 then
        raise exception 'RESIDUE: status predicate anchor occurs % times (expected 1)', v_n;
    end if;

    select pg_get_functiondef(p.oid) into v_def from pg_proc p
     where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace;

    v_def := replace(v_def,
        '      and (d.metal > 0 or d.crystal > 0);',
        '-- EPSILON 1e-9: see the migration header for the derivation. It sits above the measured'||chr(10)
     || '      -- division dust (bounded by total x 1e-20) for any field up to 1e11, and far below the'||chr(10)
     || '      -- smallest real resource amount in this system (300). Legacy dust rows must not read'||chr(10)
     || '      -- as recyclable.'||chr(10)
     || '      and (d.metal > 1e-9 or d.crystal > 1e-9);');

    execute v_def;
/* ============= POSTCONDITIONS: fix present, nothing else moved (1/2) ============= */

    if (select p.prosrc from pg_proc p
         where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_metal%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%CASE WHEN v_remaining_capacity >= v_total_debris THEN v_debris_crystal%' then
        raise exception 'POSTCONDITION FAILED: the exact full-drain branch is not deployed';
    end if;

    if (select p.prosrc from pg_proc p
         where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%ELSE LEAST(v_remaining_capacity * (v_debris_metal / v_total_debris), v_debris_metal)%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%ELSE LEAST(v_remaining_capacity * (v_debris_crystal / v_total_debris), v_debris_crystal)%' then
        raise exception 'POSTCONDITION FAILED: the partial-harvest formula was altered';
    end if;

    if (select p.prosrc from pg_proc p
         where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%v_capacity := public.calculate_recycler_capacity(p_fleet_id);%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%RAISE EXCEPTION ''Fleet % contains no Recycler''%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%RAISE EXCEPTION ''Debris field is empty''%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%GREATEST(0, d.metal - v_metal_collected)%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%DELETE FROM public.debris_fields d%'
       or (select p.prosrc from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
       not ilike '%RETURN QUERY%' then
        raise exception 'POSTCONDITION FAILED: collect_debris lost a guard, a clamp or its payload';
    end if;

    if (select p.prosrc from pg_proc p
         where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace)
       not ilike '%(d.metal > 1e-9 or d.crystal > 1e-9)%' then
        raise exception 'POSTCONDITION FAILED: the epsilon predicate is not deployed';
    end if;
/* ============= POSTCONDITIONS: contract + neighbours (2/2) ============= */

    if (select pg_get_function_arguments(p.oid) from pg_proc p
         where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace) <> ''
       or (select pg_get_function_result(p.oid) from pg_proc p
            where p.proname = 'get_recyclable_debris_status' and p.pronamespace = 'public'::regnamespace)
          <> 'TABLE(out_available boolean, out_field_count bigint)'
       or not has_function_privilege('authenticated', 'public.get_recyclable_debris_status()', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.get_recyclable_debris_status()', 'EXECUTE')
       or has_function_privilege('anon', 'public.get_recyclable_debris_status()', 'EXECUTE') then
        raise exception 'POSTCONDITION FAILED: the status contract or its ACL changed';
    end if;

    if (select pg_get_function_arguments(p.oid) from pg_proc p
         where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
          <> 'p_fleet_id uuid, p_galaxy integer, p_system integer, p_position integer'
       or (select p.provolatile from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace) <> 'v'
       or (select array_to_string(p.proconfig, ',') from pg_proc p
            where p.proname = 'collect_debris' and p.pronamespace = 'public'::regnamespace)
          <> 'search_path=public, pg_temp' then
        raise exception 'POSTCONDITION FAILED: collect_debris signature / volatility / search_path changed';
    end if;

    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'calculate_recycler_capacity' and p.pronamespace = 'public'::regnamespace)
          <> '235910c7dd6a3b31ec7ee712af2d24f1' then
        raise exception 'POSTCONDITION FAILED: calculate_recycler_capacity was modified';
    end if;

    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'start_fleet_mixed' and p.pronamespace = 'public'::regnamespace)
          <> '611d107dacf0e3869d162d11fb63fcf1' then
        raise exception 'POSTCONDITION FAILED: start_fleet_mixed was modified';
    end if;

    if (select md5(p.prosrc) from pg_proc p
         where p.proname = 'get_player_fleet_slots' and p.pronamespace = 'public'::regnamespace)
          <> '119b1100d6b13b40428545c5ebad3cf4' then
        raise exception 'POSTCONDITION FAILED: get_player_fleet_slots was modified';
    end if;

    if (select p.prosrc from pg_proc p
         where p.proname = 'process_fleet_movements' and p.pronamespace = 'public'::regnamespace)
       not ilike '%Debris field is empty%' then
        raise exception 'POSTCONDITION FAILED: the exhausted-field handler of 20261001060000 was removed';
    end if;
end;
$residue$;
-- ---------------------------------------------------------------------------------------------