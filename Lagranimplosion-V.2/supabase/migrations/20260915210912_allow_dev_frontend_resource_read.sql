drop policy if exists planet_resources_select_access on public.planet_resources;
create policy planet_resources_select_access on public.planet_resources
  for select
  to anon, authenticated
  using (
    exists (
      select 1
      from public.planets p
      join public.players pl on pl.id = p.player_id
      where p.id = planet_resources.planet_id
        and (
          pl.id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'::uuid
          or pl.user_id = (select auth.uid())
        )
    )
  );
