BEGIN;

-- The calculator only reads definition data and does not need SECURITY DEFINER.
CREATE OR REPLACE FUNCTION public.calculate_building_cost(p_building_id text, p_target_level integer)
RETURNS TABLE(building_id text, target_level integer, metal numeric, crystal numeric, deuterium numeric)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
    v_base_metal numeric;
    v_base_crystal numeric;
    v_base_deuterium numeric;
    v_cost_factor numeric;
begin
    if p_target_level < 1 then
        raise exception 'El nivel objetivo debe ser >= 1';
    end if;
    select bd.base_metal, bd.base_crystal, bd.base_deuterium, bd.cost_factor
    into v_base_metal, v_base_crystal, v_base_deuterium, v_cost_factor
    from public.building_definitions bd
    where bd.id = p_building_id;
    if not found then
        raise exception 'El edificio % no existe en building_definitions', p_building_id;
    end if;
    return query
    select p_building_id, p_target_level,
           v_base_metal * power(v_cost_factor, p_target_level - 1),
           v_base_crystal * power(v_cost_factor, p_target_level - 1),
           v_base_deuterium * power(v_cost_factor, p_target_level - 1);
end;
$function$;

COMMIT;
