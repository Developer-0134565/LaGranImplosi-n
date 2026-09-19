BEGIN;

CREATE OR REPLACE FUNCTION public.grant_planet_support_authorization(
  p_player_id uuid,
  p_planet_id uuid,
  p_guest_player_id uuid,
  p_expires_at timestamptz DEFAULT NULL
)
RETURNS TABLE(
  authorization_id uuid,
  destination_planet_id uuid,
  owner_player_id uuid,
  guest_player_id uuid,
  authorized_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_auth_user uuid := auth.uid();
  v_planet_owner uuid;
  v_id uuid;
begin
  if v_auth_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1 from public.players pl
    where pl.id = p_player_id and pl.user_id = v_auth_user
  ) then
    raise exception 'Player does not belong to authenticated user';
  end if;

  if p_planet_id is null or p_guest_player_id is null then
    raise exception 'Planet and guest player are required';
  end if;

  if p_guest_player_id = p_player_id then
    raise exception 'SUPPORT_AUTHORIZATION_SELF: a support authorization requires a foreign player';
  end if;

  select p.player_id into v_planet_owner
  from public.planets p
  where p.id = p_planet_id
    and not p.is_destroyed
  for update;

  if not found then
    raise exception 'PLANET_NOT_FOUND_OR_DESTROYED';
  end if;

  if v_planet_owner is distinct from p_player_id then
    raise exception 'PLANET_NOT_OWNED_BY_PLAYER';
  end if;

  if not exists (select 1 from public.players pl where pl.id = p_guest_player_id) then
    raise exception 'GUEST_PLAYER_NOT_FOUND';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'SUPPORT_AUTHORIZATION_EXPIRY_IN_PAST';
  end if;

  insert into public.planet_support_authorizations as psa(
    destination_planet_id, owner_player_id, guest_player_id, authorized_at, expires_at, revoked_at
  )
  values (
    p_planet_id, p_player_id, p_guest_player_id, now(), p_expires_at, null
  )
  on conflict (destination_planet_id, guest_player_id)
  do update set owner_player_id = excluded.owner_player_id,
                authorized_at = excluded.authorized_at,
                expires_at = excluded.expires_at,
                revoked_at = null
  returning psa.id into v_id;

  return query
  select a.id, a.destination_planet_id, a.owner_player_id, a.guest_player_id, a.authorized_at, a.expires_at
  from public.planet_support_authorizations a
  where a.id = v_id;
end;
$function$;

COMMIT;
