create schema if not exists private;

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_player_id uuid;
  v_universe_id uuid;
  v_username text;
begin
  select p.id
    into v_player_id
  from public.players p
  where p.user_id is null
  order by p.created_at
  limit 1;

  if v_player_id is not null then
    update public.players
       set user_id = new.id,
           last_activity_at = now()
     where id = v_player_id;

    return new;
  end if;

  select u.id
    into v_universe_id
  from public.universes u
  where u.is_active = true
  order by u.created_at
  limit 1;

  if v_universe_id is null then
    raise exception 'No active universe available for new player';
  end if;

  v_username := 'Player_' || substr(new.id::text, 1, 8);

  insert into public.players (user_id, universe_id, username)
  values (new.id, v_universe_id, v_username);

  return new;
end;
$$;

revoke all on function private.handle_new_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function private.handle_new_auth_user();

create unique index if not exists ux_players_user_id
on public.players (user_id)
where user_id is not null;

alter policy players_select_own on public.players
using ((select auth.uid()) = user_id);

alter policy planets_select_own on public.planets
using (exists (
  select 1
  from public.players pl
  where pl.id = planets.player_id
    and pl.user_id = (select auth.uid())
));

alter policy planet_resources_select_own on public.planet_resources
using (exists (
  select 1
  from public.planets p
  join public.players pl on pl.id = p.player_id
  where p.id = planet_resources.planet_id
    and pl.user_id = (select auth.uid())
));

alter policy building_queue_select_own on public.building_queue
using (exists (
  select 1
  from public.planets p
  join public.players pl on pl.id = p.player_id
  where p.id = building_queue.planet_id
    and pl.user_id = (select auth.uid())
));

alter policy research_queue_select_own on public.research_queue
using (exists (
  select 1
  from public.players pl
  where pl.id = research_queue.player_id
    and pl.user_id = (select auth.uid())
));