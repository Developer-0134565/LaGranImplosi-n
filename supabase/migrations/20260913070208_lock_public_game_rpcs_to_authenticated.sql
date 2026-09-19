revoke execute on function public.calculate_building_cost(text, integer) from anon;
revoke execute on function public.start_building(uuid, uuid, text) from anon;
revoke execute on function public.start_colonize_fleet(uuid, uuid, integer, integer, integer) from anon;
revoke execute on function public.start_fleet(uuid, uuid, uuid, text, bigint, text) from anon;
revoke execute on function public.start_lifeform_building(uuid, text) from anon;
revoke execute on function public.start_lifeform_research(uuid, text) from anon;
revoke execute on function public.start_research(uuid, uuid, text) from anon;
revoke execute on function public.start_ship(uuid, uuid, text, bigint) from anon;