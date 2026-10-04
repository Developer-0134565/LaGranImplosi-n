-- =============================================================================
-- ONBOARDING — país del comandante + cierre del parámetro muerto
-- (misión 2026-10-04, tras el fallo de login de latias125@gmail.com)
-- =============================================================================
-- CONTEXTO
--   `provision_player(p_username, p_country_code)` ya existía y aceptaba el país,
--   pero NUNCA lo usaba: calculaba `v_country` y lo descartaba, y `players` no
--   tenía columna. El parámetro era un contrato a medias. Aquí se completa.
--
--   El fallo que abrió la misión NO era de código: el Site URL de Supabase Auth
--   apuntaba a localhost:3000 y el botón "enlace mágico" del componente <Auth>
--   mandaba un email con ese enlace; quien lo abría desde su propio PC veía
--   `otp_expired`. Se corrige en el Dashboard de Supabase y desactivando el
--   enlace mágico en `src/LoginPage.tsx` (el proyecto es email/contraseña).
--
-- QUÉ HACE
--   1. Añade `players.country_code` (char(2); NULL = desconocido).
--   2. Valida: 2 letras A-Z tras `upper()`. Si no, 'XX' (mundo, sin país).
--      No se restringe a una lista: basta un alpha-2 válido.
--   3. `provision_player` deja de descartar el valor y lo persiste.
--   4. Idempotente: `IF NOT EXISTS` y default 'XX'.
--
-- LO QUE NO SE TOCA
--   Slots de flota, economía, colas ni motores de juego. Sólo identidad/onboarding.
-- =============================================================================

BEGIN;

ALTER TABLE public.players
  ADD COLUMN IF NOT EXISTS country_code char(2) NULL;

COMMENT ON COLUMN public.players.country_code IS
  'ISO-3166 alpha-2 del comandante (upper). NULL o ''XX'' = desconocido. Lo escribe provision_player desde el onboarding.';

CREATE OR REPLACE FUNCTION public.provision_player(p_username text, p_country_code text DEFAULT 'XX'::text)
 RETURNS TABLE(player_id uuid, planet_id uuid, username text, galaxy integer, system integer, planet_position integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := (select auth.uid());
  v_username text := btrim(p_username);
  v_country text;
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

  /* País: 2 letras. Cualquier otra cosa cae en 'XX'. Antes se calculaba y se
     descartaba; ahora se persiste. */
  v_country := upper(regexp_replace(coalesce(btrim(p_country_code), ''), '[^A-Za-z]', '', 'g'));
  if length(v_country) <> 2 then
    v_country := 'XX';
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

  insert into public.players (user_id, universe_id, username, last_activity_at, country_code)
  values (v_user_id, v_universe_id, v_username, now(), v_country)
  returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, galaxy, system, position,
    temperature_min, temperature_max,
    fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_galaxy, v_system, v_planet_position,
    (select t.temperature_min from public.planet_temperature_for_position(v_planet_position) t),
    (select t.temperature_max from public.planet_temperature_for_position(v_planet_position) t),
    163, 0, true, false
  ) returning id into v_planet_id;

  /* initial state: the ONE shared authority (initial endowment + initial research) */
  perform public.bootstrap_new_player_state(v_player_id, v_planet_id);

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position;
end;
$function$;

COMMENT ON FUNCTION public.provision_player(text,text) IS
  'Onboarding: crea player + Homeworld + estado inicial para el auth.uid() actual. Persiste country_code (ISO alpha-2, ''XX'' si no se pudo determinar). Idempotente.';

COMMIT;