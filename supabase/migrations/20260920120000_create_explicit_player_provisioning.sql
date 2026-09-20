-- ============================================================================
-- EXPLICIT PLAYER PROVISIONING (email/password) — replaces guest onboarding
-- ----------------------------------------------------------------------------
-- Canonical onboarding:
--   auth.uid() → provision_player() → own HUMAN player + Homeworld + resources
--                                    + initialize_player_research
--
-- Guarantees enforced here:
--   * SECURITY DEFINER with an empty search_path (all objects fully qualified);
--   * auth.uid() must be present, otherwise AUTHENTICATION_REQUIRED;
--   * reuse-first / idempotent: an existing player of the session is returned;
--   * NEVER claims, adopts or updates an existing player row
--     (no "WHERE user_id IS NULL" selection exists in this function);
--   * one transaction: player + homeworld + resources + research or nothing.
--
-- Values reused from the retired guest recipe (unchanged):
--   Homeworld · fields_total 163 · resources 500/500/0/0.
--
-- LIVE-ONLY DEPENDENCY: public.initialize_player_research(uuid) has no local
-- CREATE in this repository (baseline object) → VERIFY REQUIRED in LIVE.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.provision_player(
  p_username text,
  p_country_code text DEFAULT 'XX'
)
RETURNS TABLE(
  player_id uuid,
  planet_id uuid,
  username text,
  galaxy integer,
  system integer,
  planet_position integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
declare
  v_user_id uuid := (select auth.uid());
  v_username text := btrim(p_username);
  v_country text := upper(coalesce(nullif(btrim(p_country_code), ''), 'XX'));
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

  -- Reuse-first (idempotent): the session's own player, never somebody else's.
  select pl.id
    into v_player_id
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

  select u.id
    into v_universe_id
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
   and existing.is_destroyed = false
  where existing.id is null
  limit 1;

  if v_galaxy is null then
    raise exception 'UNIVERSE_FULL';
  end if;

  -- Empire creation (single transaction). `is_guest` is not written: the column
  -- keeps its NOT NULL DEFAULT false so this function survives its future removal.
  insert into public.players (
    user_id, universe_id, username, last_activity_at
  ) values (
    v_user_id, v_universe_id, v_username, now()
  ) returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, galaxy, system, position,
    fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_galaxy, v_system, v_planet_position,
    163, 0, true, false
  ) returning id into v_planet_id;

  insert into public.planet_resources (planet_id, metal, crystal, deuterium, energy)
  values (v_planet_id, 500, 500, 0, 0);

  -- LIVE-ONLY DEPENDENCY (baseline object, no local CREATE): VERIFY REQUIRED.
  perform public.initialize_player_research(v_player_id);

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position;
end;
$function$;

revoke execute on function public.provision_player(text, text) from public;
revoke execute on function public.provision_player(text, text) from anon;
grant execute on function public.provision_player(text, text) to authenticated;

COMMIT;

