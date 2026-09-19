create or replace function public.ui_building_definitions()
returns setof public.building_definitions
language sql
security definer
set search_path = public
as $$ select * from public.building_definitions order by id $$;

create or replace function public.ui_research_definitions()
returns setof public.research_definitions
language sql
security definer
set search_path = public
as $$ select * from public.research_definitions order by id $$;

create or replace function public.ui_ship_definitions()
returns setof public.ship_definitions
language sql
security definer
set search_path = public
as $$ select * from public.ship_definitions order by ship_type, id $$;

create or replace function public.ui_defense_definitions()
returns setof public.defense_definitions
language sql
security definer
set search_path = public
as $$ select * from public.defense_definitions order by id $$;

create or replace function public.ui_universe_galaxies()
returns setof public.universe_galaxies
language sql
security definer
set search_path = public
as $$ select * from public.universe_galaxies order by galaxy limit 100 $$;

grant execute on function public.ui_building_definitions() to anon, authenticated;
grant execute on function public.ui_research_definitions() to anon, authenticated;
grant execute on function public.ui_ship_definitions() to anon, authenticated;
grant execute on function public.ui_defense_definitions() to anon, authenticated;
grant execute on function public.ui_universe_galaxies() to anon, authenticated;