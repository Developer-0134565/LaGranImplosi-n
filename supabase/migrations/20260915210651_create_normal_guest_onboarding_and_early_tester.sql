create table if not exists public.player_achievements (
  player_id uuid not null references public.players(id) on delete cascade,
  achievement_id text not null,
  unlocked_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  primary key (player_id, achievement_id)
);

create table if not exists public.early_tester_registrations (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  ip_hash text not null unique,
  country_code text not null default 'XX',
  tester_number bigint not null unique,
  created_at timestamptz not null default now()
);

alter table public.player_achievements enable row level security;
alter table public.early_tester_registrations enable row level security;

drop policy if exists player_achievements_owner_read on public.player_achievements;
create policy player_achievements_owner_read
  on public.player_achievements
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.players pl
      where pl.id = player_achievements.player_id
        and pl.user_id = (select auth.uid())
    )
  );

drop policy if exists players_select_access on public.players;
create policy players_select_access on public.players
  for select
  to anon, authenticated
  using (
    (player_type = 'AI')
    or (is_guest = true and username <> 'DevPlayer' and user_id is not null)
    or (user_id = (select auth.uid()))
  );

drop policy if exists planets_select_access on public.planets;
create policy planets_select_access on public.planets
  for select
  to anon, authenticated
  using (is_destroyed = false);

drop policy if exists planet_resources_select_access on public.planet_resources;
create policy planet_resources_select_access on public.planet_resources
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.planets p
      join public.players pl on pl.id = p.player_id
      where p.id = planet_resources.planet_id
        and pl.user_id = (select auth.uid())
    )
  );

grant select on table public.player_achievements to authenticated;
revoke all on table public.early_tester_registrations from anon, authenticated;

create or replace function public.register_guest_player(
  p_username text,
  p_country_code text,
  p_ip_hash text
)
returns table (
  player_id uuid,
  planet_id uuid,
  username text,
  galaxy integer,
  system integer,
  planet_position integer,
  tester_number bigint,
  country_code text,
  achievement_awarded boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_is_anonymous boolean := coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false);
  v_username text := btrim(p_username);
  v_country text := upper(coalesce(nullif(btrim(p_country_code), ''), 'XX'));
  v_ip_hash text := btrim(p_ip_hash);
  v_player_id uuid;
  v_planet_id uuid;
  v_universe_id uuid;
  v_galaxy integer;
  v_system integer;
  v_planet_position integer;
  v_tester_number bigint;
  v_awarded boolean := false;
begin
  if v_user_id is null or not v_is_anonymous then
    raise exception 'ANONYMOUS_AUTH_REQUIRED';
  end if;

  if length(v_username) < 3 or length(v_username) > 24 then
    raise exception 'USERNAME_LENGTH_INVALID';
  end if;

  if v_username !~ '^[[:alnum:] _.-]+$' then
    raise exception 'USERNAME_CHARACTERS_INVALID';
  end if;

  if lower(v_username) = 'devplayer' then
    raise exception 'USERNAME_RESERVED';
  end if;

  if length(v_ip_hash) < 32 then
    raise exception 'VISITOR_ID_REQUIRED';
  end if;

  select pl.id
    into v_player_id
  from public.players pl
  where pl.user_id = v_user_id
  limit 1;

  if v_player_id is not null then
    select p.id, p.galaxy, p.system, p.position
      into v_planet_id, v_galaxy, v_system, v_planet_position
    from public.planets p
    where p.player_id = v_player_id and p.is_homeworld = true and p.is_destroyed = false
    order by p.created_at
    limit 1;

    select et.tester_number, et.country_code
      into v_tester_number, v_country
    from public.early_tester_registrations et
    where et.player_id = v_player_id
    limit 1;

    return query
      select v_player_id, v_planet_id,
             (select pl.username from public.players pl where pl.id=v_player_id),
             v_galaxy, v_system, v_planet_position, v_tester_number, v_country, false;
    return;
  end if;

  if exists (
    select 1 from public.players pl
    where pl.player_type = 'HUMAN'
      and lower(pl.username) = lower(v_username)
      and pl.is_guest = true
  ) then
    raise exception 'USERNAME_ALREADY_TAKEN';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('lgi_guest_onboarding_v1', 0));

  select u.id
    into v_universe_id
  from public.universes u
  where u.is_active = true
  order by u.created_at desc
  limit 1;

  if v_universe_id is null then
    raise exception 'ACTIVE_UNIVERSE_NOT_FOUND';
  end if;

  select slot.galaxy, slot.system, slot.planet_position
    into v_galaxy, v_system, v_planet_position
  from (
    select ug.galaxy, s.system, pos.planet_position
    from public.universe_galaxies ug
    cross join lateral generate_series(1, ug.system_count) as s(system)
    cross join lateral generate_series(1, 15) as pos(planet_position)
    where ug.universe_id = v_universe_id
    order by ug.galaxy, s.system, pos.planet_position
  ) slot
  left join public.planets existing
    on existing.universe_id = v_universe_id
   and existing.galaxy = slot.galaxy
   and existing.system = slot.system
   and existing.position = slot.planet_position
   and existing.is_destroyed = false
  where existing.id is null
  limit 1;

  if v_galaxy is null then
    raise exception 'UNIVERSE_FULL';
  end if;

  insert into public.players (
    user_id, universe_id, username, points, rank, last_activity_at, dark_matter, is_guest, player_type
  ) values (
    v_user_id, v_universe_id, v_username, 0, null, now(), 0, true, 'HUMAN'
  ) returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, galaxy, system, position, fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_galaxy, v_system, v_planet_position, 163, 0, true, false
  ) returning id into v_planet_id;

  insert into public.planet_resources (planet_id, metal, crystal, deuterium, energy)
  values (v_planet_id, 500, 500, 0, 0);

  perform public.initialize_player_research(v_player_id);

  select coalesce(max(et.tester_number), 0) + 1
    into v_tester_number
  from public.early_tester_registrations et;

  begin
    insert into public.early_tester_registrations (
      player_id, ip_hash, country_code, tester_number
    ) values (
      v_player_id, v_ip_hash, v_country, v_tester_number
    );
  exception when unique_violation then
    select et.tester_number, et.country_code
      into v_tester_number, v_country
    from public.early_tester_registrations et
    where et.ip_hash = v_ip_hash
    limit 1;
  end;

  insert into public.player_achievements (player_id, achievement_id, metadata)
  values (
    v_player_id,
    'early_tester',
    jsonb_build_object('tester_number', v_tester_number, 'country_code', v_country)
  )
  on conflict (player_id, achievement_id) do nothing;

  v_awarded := true;

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position,
           v_tester_number, v_country, v_awarded;
end;
$$;

revoke execute on function public.register_guest_player(text,text,text) from public;
revoke execute on function public.register_guest_player(text,text,text) from anon;
grant execute on function public.register_guest_player(text,text,text) to authenticated;

create index if not exists idx_players_user_id on public.players(user_id);
create index if not exists idx_player_achievements_player_id on public.player_achievements(player_id);
