CREATE OR REPLACE FUNCTION public.calculate_lifeform_building_cost(p_building_id text,p_target_level integer)
RETURNS TABLE(metal numeric,crystal numeric,deuterium numeric) LANGUAGE sql STABLE AS $function$
SELECT round(d.base_metal*power(d.cost_factor,p_target_level-1),4),round(d.base_crystal*power(d.cost_factor,p_target_level-1),4),round(d.base_deuterium*power(d.cost_factor,p_target_level-1),4)
FROM public.lifeform_building_definitions d WHERE d.id=p_building_id;
$function$;
CREATE OR REPLACE FUNCTION public.calculate_lifeform_research_cost(p_research_id text,p_target_level integer)
RETURNS TABLE(metal numeric,crystal numeric,deuterium numeric) LANGUAGE sql STABLE AS $function$
SELECT round(d.base_metal*power(d.cost_factor,p_target_level-1),4),round(d.base_crystal*power(d.cost_factor,p_target_level-1),4),round(d.base_deuterium*power(d.cost_factor,p_target_level-1),4)
FROM public.lifeform_research_definitions d WHERE d.id=p_research_id;
$function$;
