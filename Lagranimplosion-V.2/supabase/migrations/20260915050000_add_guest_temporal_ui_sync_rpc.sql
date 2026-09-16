create or replace function public.sync_current_planet_resources(
  p_player_id uuid,
  p_planet_id uuid,
  p_until timestamptz default now()
)
returns table(
  planet_id uuid,
  metal numeric,
  crystal numeric,
  deuterium numeric,
  energy numeric,
  elapsed_seconds numeric,
  metal_produced numeric,
  crystal_produced numeric,
  deuterium_produced numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_auth_user uuid;
  v_is_guest boolean;
begin
  v_auth_user := auth.uid();

  select coalesce(pl.is_guest, false)
    into v_is_guest
  from public.players pl
  where pl.id = p_player_id;

  if not found then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  if v_auth_user is not null then
    if not exists (
      select 1 from public.players pl
      where pl.id = p_player_id and pl.user_id = v_auth_user
    ) then
      raise exception 'PLAYER_ACCESS_DENIED';
    end if;
  elsif not v_is_guest then
    raise exception 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1 from public.planets p
    where p.id = p_planet_id
      and p.player_id = p_player_id
      and p.is_destroyed = false
  ) then
    raise exception 'PLANET_NOT_FOUND_OR_NOT_OWNED';
  end if;

  return query
  select * from public.update_planet_resources_until(p_planet_id, p_until);
end;
$function$;

revoke all on function public.sync_current_planet_resources(uuid, uuid, timestamptz) from public;
grant execute on function public.sync_current_planet_resources(uuid, uuid, timestamptz) to anon, authenticated;
