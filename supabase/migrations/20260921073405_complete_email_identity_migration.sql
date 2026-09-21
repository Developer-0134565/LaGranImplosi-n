-- =============================================================================
-- RECOVERED MIGRATION — 20260921073405
-- ledger name : complete_email_identity_migration
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-21 by the DEV/email identity-migration mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- -----------------------------------------------------------------------------
-- LIVE effect (independently verified read-only after the fact):
--   * created public.provision_player(text, text) and granted EXECUTE to authenticated;
--   * DROPPED trigger on_auth_user_created and private.handle_new_auth_user();
--   * DROPPED public.register_guest_player(text, text, text).
-- This single LIVE version folds the end state of the three local forward-only
-- files 20260920120000 / 20260920120100 / 20260920120200, which are preserved as
-- *.sql.superseded (never deleted) per docs/MIGRATION_DRIFT_RECONCILIATION.md.
-- =============================================================================

begin;

-- Canonical email/password onboarding: create the RPC before removing the
-- legacy auth-user trigger that used to auto-claim unowned players.
create or replace function public.provision_player(
  p_username text,
  p_country_code text default 'XX'
)
returns table(
  player_id uuid,
  planet_id uuid,
  username text,
  galaxy integer,
  system integer,
  planet_position integer
)
language plpgsql
security definer
set search_path = ''
as $function$
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
   and existing.is_destroyed = false
  where existing.id is null
  limit 1;

  if v_galaxy is null then
    raise exception 'UNIVERSE_FULL';
  end if;

  insert into public.players (user_id, universe_id, username, last_activity_at)
  values (v_user_id, v_universe_id, v_username, now())
  returning id into v_player_id;

  insert into public.planets (
    universe_id, player_id, name, galaxy, system, position,
    fields_total, fields_used, is_homeworld, is_destroyed
  ) values (
    v_universe_id, v_player_id, 'Homeworld', v_galaxy, v_system, v_planet_position,
    163, 0, true, false
  ) returning id into v_planet_id;

  insert into public.planet_resources (planet_id, metal, crystal, deuterium, energy)
  values (v_planet_id, 500, 500, 0, 0);

  perform public.initialize_player_research(v_player_id);

  return query
    select v_player_id, v_planet_id, v_username, v_galaxy, v_system, v_planet_position;
end;
$function$;

revoke execute on function public.provision_player(text, text) from public;
revoke execute on function public.provision_player(text, text) from anon;
grant execute on function public.provision_player(text, text) to authenticated;

-- The old trigger could auto-claim an arbitrary user_id IS NULL player.
drop trigger if exists on_auth_user_created on auth.users;
drop function if exists private.handle_new_auth_user();

-- Guest onboarding is no longer part of the product model.
drop function if exists public.register_guest_player(text, text, text);

commit;
