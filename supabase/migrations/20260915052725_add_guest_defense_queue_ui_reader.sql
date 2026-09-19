create or replace function public.ui_defense_queue(p_player_id uuid, p_planet_id uuid)
returns setof public.defense_queue
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.planets p
    where p.id = p_planet_id and p.player_id = p_player_id and not p.is_destroyed
  ) then
    raise exception 'PLANET_ACCESS_DENIED';
  end if;
  return query
  select q.* from public.defense_queue q
  where q.planet_id = p_planet_id
    and q.status in ('BUILDING','QUEUED')
  order by q.finishes_at;
end;
$$;
grant execute on function public.ui_defense_queue(uuid,uuid) to anon, authenticated;