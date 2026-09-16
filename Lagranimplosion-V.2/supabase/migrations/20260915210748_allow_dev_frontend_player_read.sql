drop policy if exists players_select_access on public.players;
create policy players_select_access on public.players
  for select
  to anon, authenticated
  using (
    id = 'aa1deb2d-3ed6-4350-922a-172d999b2af7'::uuid
    or (player_type = 'AI')
    or (is_guest = true and username <> 'DevPlayer' and user_id is not null)
    or (user_id = (select auth.uid()))
  );
