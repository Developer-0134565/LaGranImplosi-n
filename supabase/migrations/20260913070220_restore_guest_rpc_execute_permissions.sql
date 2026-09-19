grant execute on function public.calculate_building_cost(text, integer) to anon;
grant execute on function public.start_building(uuid, uuid, text) to anon;
grant execute on function public.start_colonize_fleet(uuid, uuid, integer, integer, integer) to anon;
grant execute on function public.start_fleet(uuid, uuid, uuid, text, bigint, text) to anon;
grant execute on function public.start_lifeform_building(uuid, text) to anon;
grant execute on function public.start_lifeform_research(uuid, text) to anon;
grant execute on function public.start_research(uuid, uuid, text) to anon;
grant execute on function public.start_ship(uuid, uuid, text, bigint) to anon;