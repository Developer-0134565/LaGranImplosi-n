create or replace function public.enforce_player_write_access()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid;
  v_is_guest boolean;
  v_user_id uuid;
begin
  if tg_table_name = 'research_queue' then
    v_player_id := new.player_id;
  elsif tg_table_name in ('building_queue','shipyard_queue') then
    select p.player_id into v_player_id
    from public.planets p
    where p.id = new.planet_id;
  elsif tg_table_name = 'fleet_movements' then
    v_player_id := new.player_id;
  else
    raise exception 'Unsupported protected table: %', tg_table_name;
  end if;

  if v_player_id is null then
    raise exception 'PLAYER_ACCESS_DENIED';
  end if;

  select pl.is_guest, pl.user_id
    into v_is_guest, v_user_id
  from public.players pl
  where pl.id = v_player_id;

  if not found then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  v_user_id := auth.uid();

  if v_user_id is null then
    if coalesce(v_is_guest, false) is not true then
      raise exception 'AUTHENTICATION_REQUIRED';
    end if;
  elsif v_user_id is distinct from (select pl.user_id from public.players pl where pl.id = v_player_id) then
    raise exception 'PLAYER_NOT_OWNED_BY_AUTH_USER';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_player_write_access() from public;
grant execute on function public.enforce_player_write_access() to anon, authenticated;

drop trigger if exists trg_enforce_player_write_building_queue on public.building_queue;
create trigger trg_enforce_player_write_building_queue
before insert on public.building_queue
for each row execute function public.enforce_player_write_access();

drop trigger if exists trg_enforce_player_write_research_queue on public.research_queue;
create trigger trg_enforce_player_write_research_queue
before insert on public.research_queue
for each row execute function public.enforce_player_write_access();

drop trigger if exists trg_enforce_player_write_shipyard_queue on public.shipyard_queue;
create trigger trg_enforce_player_write_shipyard_queue
before insert on public.shipyard_queue
for each row execute function public.enforce_player_write_access();

drop trigger if exists trg_enforce_player_write_fleet_movements on public.fleet_movements;
create trigger trg_enforce_player_write_fleet_movements
before insert on public.fleet_movements
for each row execute function public.enforce_player_write_access();