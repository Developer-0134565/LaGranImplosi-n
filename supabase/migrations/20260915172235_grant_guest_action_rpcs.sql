grant execute on function public.start_building(uuid, uuid, text) to anon;
grant execute on function public.start_research(uuid, uuid, text) to anon;
grant execute on function public.start_ship(uuid, uuid, text, bigint) to anon;
-- start_defense already has anon EXECUTE, so leave it unchanged.