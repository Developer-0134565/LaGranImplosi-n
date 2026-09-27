-- ============================================================================
-- FIX — ai_composition_power: unknown-owner hull convention (forward-only)
-- ----------------------------------------------------------------------------
-- The certified combat helpers divide the stored hull by 10 before applying armour technology:
--
--   get_combat_ship_hull     -> (sd.hull / 10)     * (1 + armour_technology * 0.10)
--   get_combat_defense_hull  -> (dd.hull / 10)     * (1 + armour_technology * 0.10)
--
-- 20260926290000 read the raw hull for the unknown-owner path (an espionage target), which inflated a
-- target's estimated power by an order of magnitude on the hull component and therefore made the AI
-- systematically overestimate defenders. Forward-only fix: the unknown path uses the SAME hull convention
-- as the certified helpers, so the estimate is like-for-like with the AI's own strength (which always goes
-- through the helpers). The documented 1.15 conservatism for unknown research levels is unchanged.
-- ============================================================================

create or replace function public.ai_composition_power(p_ships jsonb, p_defenses jsonb, p_player_id uuid default null)
returns numeric
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_power numeric := 0;
    v_unit record;
    v_qty numeric;
    v_a numeric; v_s numeric; v_h numeric;
begin
    /* p_player_id known -> certified helpers (real weapons/shielding/armour levels).
       p_player_id null  -> the definitions' base stats (hull/10, the certified convention) plus a
       conservative 1.15 factor, because an LGI espionage report carries no research. */
    for v_unit in select key as id, (value #>> '{}')::numeric as qty
                    from jsonb_each(coalesce(p_ships, '{}'::jsonb)) loop
        v_qty := coalesce(v_unit.qty, 0);
        if v_qty <= 0 then continue; end if;
        if p_player_id is null then
            select sd.attack, sd.shield, (sd.hull / 10) into v_a, v_s, v_h
              from public.ship_definitions sd where sd.id = v_unit.id;
            v_power := v_power + v_qty * (coalesce(v_a,0) + coalesce(v_s,0) + coalesce(v_h,0)) * 1.15;
        else
            v_power := v_power + v_qty * (
                  coalesce(public.get_combat_ship_attack(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_ship_shield(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_ship_hull(p_player_id, v_unit.id), 0));
        end if;
    end loop;

    for v_unit in select key as id, (value #>> '{}')::numeric as qty
                    from jsonb_each(coalesce(p_defenses, '{}'::jsonb)) loop
        v_qty := coalesce(v_unit.qty, 0);
        if v_qty <= 0 then continue; end if;
        if p_player_id is null then
            select dd.attack, dd.shield, (dd.hull / 10) into v_a, v_s, v_h
              from public.defense_definitions dd where dd.id = v_unit.id;
            v_power := v_power + v_qty * (coalesce(v_a,0) + coalesce(v_s,0) + coalesce(v_h,0)) * 1.15;
        else
            v_power := v_power + v_qty * (
                  coalesce(public.get_combat_defense_attack(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_defense_shield(p_player_id, v_unit.id), 0)
                + coalesce(public.get_combat_defense_hull(p_player_id, v_unit.id), 0));
        end if;
    end loop;

    return round(v_power, 2);
end;
$function$;