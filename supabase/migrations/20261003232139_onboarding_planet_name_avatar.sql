BEGIN;

ALTER TABLE public.planets ADD COLUMN IF NOT EXISTS planet_name text NULL;
COMMENT ON COLUMN public.planets.planet_name IS
  'Nombre elegido por el jugador en el onboarding. NULL = nombre por defecto (Homeworld). No es único: la identidad del planeta son sus coordenadas.';

ALTER TABLE public.players ADD COLUMN IF NOT EXISTS avatar_id text NULL;
COMMENT ON COLUMN public.players.avatar_id IS
  'Clave del emblema de comandante (src/lib/avatars.tsx). NULL = default. El servidor no valida contra lista: la UI resuelve el fallback.';

CREATE OR REPLACE FUNCTION public.provision_player(
  p_username text,
  p_country_code text DEFAULT 'XX',
  p_planet_name text DEFAULT NULL,
  p_avatar_id text DEFAULT NULL)
 RETURNS TABLE(player_id uuid, planet_id uuid, username text, galaxy integer, system integer, planet_position integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := (select auth.uid());
  v_username text := btrim(p_username);
  v_country text;
  v_pname text;
  v_avatar text;
  v_player_id uuid;
  v_planet_id uuid;
  v_universe_id uuid;
  v_galaxy integer;
  v_system integer;
  v_planet_position integer;
begin
  if v_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED';
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

  v_country := upper(regexp_replace(coalesce(btrim(p_country_code), ''), '[^A-Za-z]', '', 'g'));
  if length(v_country) <> 2 then
    v_country := 'XX';
  end if;

  v_pname := nullif(btrim(coalesce(p_planet_name, '')), '');
  if v_pname is not null
     and (length(v_pname) > 32 or v_pname !~ '^[[:alnum:] ._-]+$') then
    v_pname := null;
  end if;

  v_avatar := nullif(btrim(coalesce(p_avatar_id, '')), '');
  if v_avatar is not null and v_avatar !~ '^[a-z0-9_-]{1,32}$' then
    v_avatar := null;
  end if;

  select pl.id into v_player_id
  from public.players pl
  where pl.user_id = v_user_id
  limit 1;

  if v_player_id is not null then
    select p.id, p.galaxy, p.system, p.position
      into v_planet_id, v_galaxy, v_system, v_planet_position
    from public.planets p
    where p.player_id = v_player_id
      and p.is_homeworld = true
      and p.is_destroyed = false
    order by p.created_at
    limit 1;

    return query
      select v_player_id, v_planet_id,
             (select pl.username from public.players pl where pl.id = v_player_id),
             v_galaxy, v_system, v_planet_position;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('lgi_player_provisioning_v1', 0));

  select u.id into v_universe_id
  from public.universes u
  where u.is_active = true
  order by u.created_at desc
  limit 1;

  if v_universe_id is null then
    raise exception 'ACTIVE_UNIVERSE_NOT_FOUND';
  end if;

  if exists (
    select 1 from public.players pl
    where pl.universe_id = v_universe_id
      and pl.player_type = 'HUMAN'
      and lower(pl.username) = lower(v_username)
  ) then
    raise exception 'USERNAME_ALREADY_TAKEN';
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
           and existing.kind = 'PLANET'
   and existing.is_destroyed = false
  where existing.id is null
  limit 1;

  if v_galaxy is null then
    raise exception 'UNIVERSE_FULL';
  end if;

  insert into public.players (user_id, universe_id, username, last_activity_at, country_code, avatar_id)
  values (v_user_id, v_universe_id, v_username, now(), v_country, v_avatar)
  returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, planet_name, galaxy, system, position,
    temperature_min, temperature_max,
    fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_pname, v_galaxy, v_system, v_planet_position,
    (select t.temperature_min from public.planet_temperature_for_position(v_planet_position) t),
    (select t.temperature_max from public.planet_temperature_for_position(v_planet_position) t),
    163, 0, true, false
  ) returning id into v_planet_id;

  perform public.bootstrap_new_player_state(v_player_id, v_planet_id);

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position;
end;
$function$;

COMMENT ON FUNCTION public.provision_player(text,text,text,text) IS
  'Onboarding: crea player + Homeworld + estado inicial para el auth.uid() actual. Persiste country_code, planet_name y avatar_id. Idempotente (reuse-first).';

COMMIT;