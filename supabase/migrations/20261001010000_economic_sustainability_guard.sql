-- LGI ECONOMIC SOFTLOCK GUARD — autosustainability pre-flight (mission 2026-10-01)
--
-- PRODUCT DECISION (approved, deliberate exception to a previous LGI rule):
--   A player must not be able to start an action that leaves the planet unable to
--   self-supply WHEN A REASONABLE ECONOMIC ALTERNATIVE to recover/protect production exists.
--   "Energy = information, never a gate" (README_ECONOMY.md:169-171) is NOT reverted: low
--   energy never blocks a construction. What is blocked is only the specific case where the
--   POST-ACTION state provably collapses production to zero with no affordable way out.
--
-- WHY HERE AND NOT IN start_building:
--   `evaluate_building_start_internal` is the single certified oracle that
--   `can_start_building` (client contract), `get_planet_building_preview` and the AI policy
--   (`ai_decide_and_act_core` -> can_start_building) all already consult. Guarding it gives
--   ONE authoritative path shared by PLAYER and AI — no second formula, and the backend
--   stays the last barrier even if the AI planner changes.
--
-- SUSTAINABILITY DEFINITION (LGI's own formula, not an invented one):
--   Production is f(..., production_factor) with
--       production_factor := GREATEST(0, LEAST(1, energy_production / energy_consumption))
--   therefore the planet self-supplies iff consumption = 0 OR production > 0.
--   A soft-lock is exactly: consumption_after > 0 AND production_after <= 0.
--
-- SIMULATION IS PURE: no mutation, no rollback trick. The post-action state is derived
--   arithmetically from the certified energy helpers.
--
-- SCOPE — only buildings that can move energy are guarded. The helper returns
--   applicable = false for anything that cannot change energy, so nothing else is
--   blocked indiscriminately (research, ships, defences, storage... are untouched).
-- ---------------------------------------------------------------------------------------------

-- Energy effect of a hypothetical building level, expressed in LGI's own units.
-- Positive = produces energy (solar_plant, fusion_plant), negative = consumes it (mines).
-- Reuses calculate_building_energy_consumption for consumption and the SAME solar/fusion
-- formulas that calculate_planet_production applies (20*L*1.1^L, 30*L*...).
create or replace function public.calculate_building_energy_output(p_building_id text, p_level integer)
returns numeric language plpgsql immutable set search_path to 'public','pg_temp' as $f$
declare v numeric := 0;
begin
    if p_level is null or p_level < 1 then return 0; end if;

    if p_building_id = 'solar_plant' then
        v := floor(20 * p_level * power(1.1, p_level));
    elsif p_building_id = 'fusion_plant' then
        v := floor(30 * p_level * power(1.05, p_level));
    else
        v := 0;
    end if;

    return v - public.calculate_building_energy_consumption(p_building_id, greatest(p_level, 0));
end;
$f$;

comment on function public.calculate_building_energy_output(text, integer) is
    'Efecto energetico neto de un nivel de edificio, en las mismas unidades que usa calculate_planet_production: positivo produce energia (solar_plant/fusion_plant), negativo la consume (minas). Reutiliza calculate_building_energy_consumption.';
-- AUTHORITATIVE PRE-FLIGHT: would starting this building make the planet unable to
-- self-supply, while a reasonable economic recovery still exists?
create or replace function public.evaluate_economic_sustainability(
    p_planet_id uuid,
    p_building_id text,
    p_target_level integer
)
returns table (
    applicable             boolean,
    blocks                 boolean,
    reason_code            text,
    reason                 text,
    energy_production_now  numeric,
    energy_consumption_now numeric,
    energy_production_after numeric,
    energy_consumption_after numeric,
    production_factor_after numeric,
    recovery_available     boolean
)
language plpgsql stable security definer set search_path to 'public','pg_temp' as $f$
declare
    v_now record;
    v_delta numeric := 0;
    v_prod_after numeric;
    v_cons_after numeric;
    v_factor_after numeric := 1;
    v_deut numeric := 0;
    v_current integer := 0;
    v_solar_after integer := 0;
    v_solar_prod numeric := 0;
    v_fusion_after integer := 0;
    v_fusion_prod numeric := 0;
    v_cheapest_recovery numeric;
    v_stock numeric := 0;
begin
    select * into v_now from public.calculate_planet_energy_balance(p_planet_id);
    if not found then
        return query select false, false, 'PLANET_NOT_FOUND', 'El planeta no existe', 0,0,0,0,0,false;
        return;
    end if;

    select coalesce(deuterium,0) into v_deut from public.planet_resources where planet_id = p_planet_id;
    select coalesce(metal,0) into v_stock from public.planet_resources where planet_id = p_planet_id;

    /* ---- energy delta introduced by this action, in LGI's own units ---- */
    if p_building_id = 'solar_plant' then
        v_delta := public.calculate_building_energy_output('solar_plant', p_target_level)
                 - public.calculate_building_energy_output('solar_plant', p_target_level - 1);
    elsif p_building_id = 'fusion_plant' and v_deut > 0 then
        v_delta := public.calculate_building_energy_output('fusion_plant', p_target_level)
                 - public.calculate_building_energy_output('fusion_plant', p_target_level - 1);
    else
        v_delta := public.calculate_building_energy_consumption(p_building_id, p_target_level)
                 - public.calculate_building_energy_consumption(p_building_id, p_target_level - 1);
    end if;

    /* ---- applicable only when this action actually moves energy ---- */
    if v_delta = 0 then
        return query select false, false, 'NOT_APPLICABLE', 'La accion no altera la energia',
            v_now.energy_production_per_hour, v_now.energy_consumption_per_hour,
            v_now.energy_production_per_hour, v_now.energy_consumption_per_hour,
            case when v_now.energy_consumption_per_hour > 0
                 then least(1, v_now.energy_production_per_hour / v_now.energy_consumption_per_hour)
                 else 1 end, false;
        return;
    end if;

    /* A negative delta only raises consumption; only a positive delta can raise production. */
    if v_delta > 0 then
        v_prod_after := greatest(0, v_now.energy_production_per_hour + v_delta);
        v_cons_after := v_now.energy_consumption_per_hour;
    else
        v_prod_after := v_now.energy_production_per_hour;
        v_cons_after := greatest(0, v_now.energy_consumption_per_hour + v_delta);
    end if;

    if v_cons_after > 0 then
        v_factor_after := greatest(0, least(1, v_prod_after / v_cons_after));
    end if;
/* ---- is there a reasonable economic way out? (the escape hatch the decision names) ---- */
    select coalesce(max(level),0) into v_current from public.planet_buildings
     where planet_id = p_planet_id and building_id = 'solar_plant';
    v_solar_after := case when p_building_id = 'solar_plant' then p_target_level else v_current end;
    v_solar_prod  := case when v_solar_after = 0 then 0
                          else public.calculate_building_energy_output('solar_plant', v_solar_after) end;

    select coalesce(max(level),0) into v_fusion_after from public.planet_buildings
     where planet_id = p_planet_id and building_id = 'fusion_plant';
    if p_building_id = 'fusion_plant' then v_fusion_after := p_target_level; end if;
    v_fusion_prod := case when v_fusion_after = 0 or v_deut <= 0 then 0
                          else public.calculate_building_energy_output('fusion_plant', v_fusion_after) end;

    v_cheapest_recovery := least(
        (select (public.calculate_building_cost('solar_plant', greatest(v_solar_after,0) + 1)).metal),
        (select (public.calculate_building_cost('fusion_plant', greatest(v_fusion_after,0) + 1)).metal));

    return query select
        true,
        (v_factor_after = 0 and v_cons_after > 0 and v_prod_after <= 0),
        case when v_factor_after = 0 and v_cons_after > 0 and v_prod_after <= 0
             then 'INSUFFICIENT_ENERGY_SUSTAINABILITY' else 'SUSTAINABLE' end,
        case when v_factor_after = 0 and v_cons_after > 0 and v_prod_after <= 0
             then 'Esta mejora dejaria al planeta sin produccion de energia suficiente: la produccion de recursos se detendria de forma permanente. Investiga o construye primero una mejora energetica.'
             else 'El planeta seguira pudiendo producir recursos.' end,
        v_now.energy_production_per_hour,
        v_now.energy_consumption_per_hour,
        v_prod_after, v_cons_after, v_factor_after,
        (v_prod_after + greatest(v_solar_prod,0) + greatest(v_fusion_prod,0) > 0)
        or (v_stock >= v_cheapest_recovery);
end;
$f$;

comment on function public.evaluate_economic_sustainability(uuid, text, integer) is
    'Pre-flight ECONOMICO autoritativo. Simula el estado POST-accion por calculo puro (sin mutar el planeta) usando las mismas funciones de energia que calculate_planet_production. blocks = true exactamente cuando el estado posterior deja production_factor = 0 con consumo > 0 Y existe alternativa economica razonable de recuperacion. Es la MISMA autoridad que consumen el jugador (can_start_building) y la IA (ai_decide_and_act_core).';

-- Client-facing read contract: same pre-flight, owner-scoped (auth.uid() -> players.user_id).
-- The player never sends a player id. 0 rows for a foreign/destroyed planet, never an exception.
create or replace function public.get_economic_sustainability_check(p_planet_id uuid, p_building_id text)
returns table (
    allowed                boolean,
    reason_code            text,
    reason                 text,
    energy_production_now  numeric,
    energy_consumption_now numeric,
    energy_production_after numeric,
    energy_consumption_after numeric,
    production_factor_after numeric,
    recovery_available     boolean
)
language plpgsql stable security definer set search_path to 'public','pg_temp' as $f$
declare
    v_auth uuid := auth.uid();
    v_player uuid;
    v_current integer;
    v_target integer;
    v_sust record;
begin
    if v_auth is null or p_planet_id is null or p_building_id is null then return; end if;

    select pl.id into v_player from public.players pl where pl.user_id = v_auth;
    if v_player is null then return; end if;

    if not exists (select 1 from public.planets p
                    where p.id = p_planet_id and p.player_id = v_player and p.is_destroyed = false) then
        return;
    end if;

    select coalesce(max(pb.level),0) into v_current from public.planet_buildings pb
     where pb.planet_id = p_planet_id and pb.building_id = p_building_id;
    v_target := v_current + 1;

    select * into v_sust
      from public.evaluate_economic_sustainability(p_planet_id, p_building_id, v_target);
    if not found then return; end if;

    return query select
        (not v_sust.blocks), v_sust.reason_code, v_sust.reason,
        v_sust.energy_production_now, v_sust.energy_consumption_now,
        v_sust.energy_production_after, v_sust.energy_consumption_after,
        v_sust.production_factor_after, v_sust.recovery_available;
end;
$f$;

revoke all on function public.get_economic_sustainability_check(uuid, text) from public, anon;
revoke all on function public.calculate_building_energy_output(text, integer) from public, anon, authenticated;
revoke all on function public.evaluate_economic_sustainability(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.get_economic_sustainability_check(uuid, text) to authenticated;
grant execute on function public.evaluate_economic_sustainability(uuid, text, integer) to service_role;
grant execute on function public.calculate_building_energy_output(text, integer) to service_role;
-- ---------------------------------------------------------------------------------------------
-- 3. WIR THE GUARD INTO THE SINGLE SHARED ORACLE
--    `evaluate_building_start_internal` is the ONE certified oracle that
--    `can_start_building` (client contract), `get_planet_building_preview` (read contract) and
--    `ai_decide_and_act_core` (AI policy) already funnel through. Guarding it protects PLAYER
--    and AI through the SAME authoritative path, so the backend stays the last barrier even if
--    the AI planner changes later.
--
--    The body is edited SURGICALLY (an anchored text splice), NOT retyped: every certified
--    branch, cost, prerequisite and reason string is preserved byte-for-byte. The only change is
--    one new branch immediately before the final OK return, plus one `record` declaration.
--    This keeps the "one computation, no second oracle" property intact.
-- ---------------------------------------------------------------------------------------------
do $wire$
declare
    v_oid oid;
    v_src text;
    v_def text;
    v_pos integer;
    v_insert integer;
    v_cursor integer;
    v_new text;
    v_guard text;
begin
    select p.oid, p.prosrc into v_oid, v_src
      from pg_proc p
     where p.proname = 'evaluate_building_start_internal'
       and p.pronamespace = 'public'::regnamespace;
    if v_oid is null then
        raise exception 'ECONOMIC_GUARD_WIRE: evaluate_building_start_internal not found';
    end if;

    -- idempotent: never wire twice
    if v_src like '%evaluate_economic_sustainability%' then
        raise notice 'ECONOMIC_GUARD_WIRE: already wired, nothing to do';
        return;
    end if;

    /* ---- the guard block, computed ONCE and reused by both splices ---- */
    v_guard :=
          E'    /*\r\n'
       || E'     * ECONOMIC SUSTAINABILITY PRE-FLIGHT (2026-10-01) - AUTOSUSTAINABILITY GUARD\r\n'
       || E'     *\r\n'
       || E'     * PRODUCT DECISION: an action may not leave the planet unable to self-supply\r\n'
       || E'     * WHEN a reasonable economic alternative still exists. This is a DELIBERATE,\r\n'
       || E'     * MORE SPECIFIC exception to "energy = information, never a gate"\r\n'
       || E'     * (README_ECONOMY.md:169-171): low energy never blocks a construction; only a\r\n'
       || E'     * provable post-action collapse of production to zero is blocked.\r\n'
       || E'     *\r\n'
       || E'     * The pre-flight is a PURE simulation of the post-action state (no mutation, no\r\n'
       || E'     * rollback) built on the same energy helpers calculate_planet_production uses.\r\n'
       || E'     *\r\n'
       || E'     * Placement matters: this is the single oracle shared by can_start_building\r\n'
       || E'     * (client), get_planet_building_preview (read) and ai_decide_and_act_core (AI), so\r\n'
       || E'     * player and AI are protected by ONE authority - not two formulas.\r\n'
       || E'     */\r\n'
       || E'    SELECT *\r\n'
       || E'      INTO v_sustainability\r\n'
       || E'      FROM public.evaluate_economic_sustainability(p_planet_id, p_building_id, v_target_level);\r\n'
       || E'\r\n'
       || E'    IF COALESCE(v_sustainability.blocks, false)\r\n'
       || E'       AND COALESCE(v_sustainability.recovery_available, true)\r\n'
       || E'    THEN\r\n'
       || E'        RETURN QUERY SELECT\r\n'
       || E'            false,\r\n'
       || E'            v_sustainability.reason,\r\n'
       || E'            v_current_level,\r\n'
       || E'            v_target_level,\r\n'
       || E'            v_cost.metal,\r\n'
       || E'            v_cost.crystal,\r\n'
       || E'            v_cost.deuterium,\r\n'
       || E'            v_metal,\r\n'
       || E'            v_crystal,\r\n'
       || E'            v_deuterium,\r\n'
       || E'            true,\r\n'
       || E'            true,\r\n'
       || E'            v_queue_available;\r\n'
       || E'        RETURN;\r\n'
       || E'    END IF;\r\n'
       || E'\r\n';

    /* ---- Splice the edits into the COMPLETE `CREATE OR REPLACE FUNCTION` statement returned
            by pg_get_functiondef, so the signature, RETURNS TABLE, volatility, security and
            `SET search_path` are reproduced verbatim by PostgreSQL itself. Hand-assembling the
            DDL with format() silently dropped proconfig and produced invalid SQL. ---- */
    v_def := replace(pg_get_functiondef(v_oid),
                     'v_prerequisite record;',
                     'v_prerequisite record;' || chr(13) || chr(10) || '    v_sustainability record;');

    v_pos := strpos(v_def, 'TODO CORRECTO');
    if v_pos = 0 then
        raise exception 'ECONOMIC_GUARD_WIRE: OK-return anchor not found in function definition';
    end if;
    -- start of the ' * TODO CORRECTO' line
    v_insert := v_pos;
    while substring(v_def, v_insert - 1, 1) <> E'\n' loop v_insert := v_insert - 1; end loop;
    -- start of the '/*' line that OPENS that comment: consumed together with the TODO comment
    v_cursor := v_insert - 1;
    while substring(v_def, v_cursor - 1, 1) <> E'\n' loop v_cursor := v_cursor - 1; end loop;

    v_new := substring(v_def, 1, v_cursor - 1) || E'\r\n' || v_guard
          || substring(v_def from v_cursor);

    execute v_new;
end;
$wire$;