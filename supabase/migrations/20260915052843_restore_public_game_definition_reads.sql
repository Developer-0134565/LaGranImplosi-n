drop policy if exists deny_direct_api_access on public.building_definitions;
drop policy if exists deny_direct_api_access on public.research_definitions;
drop policy if exists deny_direct_api_access on public.defense_definitions;
drop policy if exists deny_direct_api_access on public.universe_galaxies;
drop policy if exists deny_direct_api_access on public.defense_queue;

create policy building_definitions_public_read on public.building_definitions for select to anon, authenticated using (true);
create policy research_definitions_public_read on public.research_definitions for select to anon, authenticated using (true);
create policy defense_definitions_public_read on public.defense_definitions for select to anon, authenticated using (true);
create policy universe_galaxies_public_read on public.universe_galaxies for select to anon, authenticated using (true);
create policy defense_queue_owner_read on public.defense_queue for select to anon, authenticated using (
  exists (
    select 1 from public.planets p
    where p.id = defense_queue.planet_id
      and p.is_destroyed = false
      and exists (select 1 from public.players pl where pl.id = p.player_id and pl.is_guest = true)
  )
);