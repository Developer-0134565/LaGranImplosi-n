-- ============================================================================
-- ACS_HOLD BLOCKER — support authorization conflict resolution
-- ----------------------------------------------------------------------------
-- Defect (measured LIVE 2026-09-22):
--
--   grant_planet_support_authorization(...) raised
--     ERROR 42702 :: column reference "destination_planet_id" is ambiguous
--
--   The function RETURNS TABLE(authorization_id, destination_planet_id,
--   owner_player_id, guest_player_id, ...), so those names are PL/pgSQL
--   variables inside the body. The INSERT resolved its conflict target as
--       on conflict (destination_planet_id, guest_player_id)
--   which is ambiguous between the OUT-parameter variables and the table
--   columns, so the statement aborted at runtime.
--
--   Consequences, also measured LIVE:
--     · no support authorization could ever be created (table stayed at 0 rows);
--     · start_support_fleet therefore always raised SUPPORT_AUTHORIZATION_REQUIRED;
--     · the whole ACS_HOLD dispatch was unreachable end-to-end, with 0 support rows.
--
-- A/B reproduction performed before this migration (rollback-safe, on this very
-- table and with the same OUT-parameter names):
--     A. on conflict (destination_planet_id, guest_player_id)          -> 42702
--     B. on conflict on constraint planet_support_authorizations_
--        destination_guest_key                                        -> OK, 1 row
--     second identical call                                            -> OK, still 1 row (upsert)
--
-- This migration therefore changes ONLY the conflict target resolution: the
-- unique constraint is named, so no identifier can be ambiguous. Everything
-- else is byte-for-byte the previous behaviour.
--
-- Explicitly preserved (asserted in the post-conditions below):
--   · the public signature, including `p_expires_at ... DEFAULT NULL`;
--   · SECURITY DEFINER, owner postgres, search_path public, pg_temp;
--   · the ACL (no widening: anon/public stay out, authenticated/service_role in);
--   · every authorization check, error message and the upsert semantics;
--   · no policy, no table, no column, no second authorization mechanism.
--
-- Note: the LOCAL_ONLY / NOT_DEPLOYED / BLOCKED migration
-- 20260919180000_fix_planet_support_authorization_ambiguity.sql does NOT fix this
-- defect — it re-declares the same `on conflict (destination_planet_id,
-- guest_player_id)` form. It remains blocked and is left untouched.
-- ============================================================================

create or replace function public.grant_planet_support_authorization(
  p_player_id uuid,
  p_planet_id uuid,
  p_guest_player_id uuid,
  p_expires_at timestamptz default null
)
returns table(
  authorization_id uuid,
  destination_planet_id uuid,
  owner_player_id uuid,
  guest_player_id uuid,
  authorized_at timestamptz,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $grant_support$
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

  insert into public.planet_support_authorizations(
    destination_planet_id, owner_player_id, guest_player_id, authorized_at, expires_at, revoked_at
  )
  values (
    p_planet_id, p_player_id, p_guest_player_id, now(), p_expires_at, null
  )
  on conflict on constraint planet_support_authorizations_destination_guest_key
  do update set owner_player_id = excluded.owner_player_id,
                authorized_at = excluded.authorized_at,
                expires_at = excluded.expires_at,
                revoked_at = null
  returning planet_support_authorizations.id into v_id;

  return query
  select a.id, a.destination_planet_id, a.owner_player_id, a.guest_player_id, a.authorized_at, a.expires_at
  from public.planet_support_authorizations a
  where a.id = v_id;
end;
$grant_support$;

-- ACL: CREATE OR REPLACE preserves the existing ACL, but the privilege state is
-- re-declared explicitly so it can never silently fall back to PUBLIC EXECUTE.
revoke all on function public.grant_planet_support_authorization(uuid, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.grant_planet_support_authorization(uuid, uuid, uuid, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- Post-conditions
-- ---------------------------------------------------------------------------
do $acs_a$
begin
  if (select count(*) from pg_proc p
       where p.pronamespace='public'::regnamespace
         and p.proname='grant_planet_support_authorization') <> 1 then
    raise exception 'ACS-A: expected exactly one grant_planet_support_authorization definition';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname='grant_planet_support_authorization'
      and p.prosecdef
      and pg_get_userbyid(p.proowner)='postgres'
      and coalesce(array_to_string(p.proconfig,','),'') like '%search_path=public, pg_temp%'
  ) then
    raise exception 'ACS-A: grant_planet_support_authorization lost its bounded definer shape';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname='grant_planet_support_authorization'
      and p.prosrc like '%on conflict (destination_planet_id, guest_player_id)%'
  ) then
    raise exception 'ACS-A: the ambiguous conflict target is still present';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname='grant_planet_support_authorization'
      and p.prosrc like '%on conflict on constraint planet_support_authorizations_destination_guest_key%'
  ) then
    raise exception 'ACS-A: the unambiguous conflict target was not installed';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname='grant_planet_support_authorization'
      and p.prosrc like '%Authentication required%'
      and p.prosrc like '%Player does not belong to authenticated user%'
      and p.prosrc like '%SUPPORT_AUTHORIZATION_SELF%'
      and p.prosrc like '%PLANET_NOT_FOUND_OR_DESTROYED%'
      and p.prosrc like '%PLANET_NOT_OWNED_BY_PLAYER%'
      and p.prosrc like '%GUEST_PLAYER_NOT_FOUND%'
      and p.prosrc like '%SUPPORT_AUTHORIZATION_EXPIRY_IN_PAST%'
  ) then
    raise exception 'ACS-A: an authorization check was lost';
  end if;

  if not exists (
    select 1 from pg_proc p
    where p.pronamespace='public'::regnamespace
      and p.proname='grant_planet_support_authorization'
      and p.proargnames::text like '%p_expires_at%'
  ) then
    raise exception 'ACS-A: the public signature lost p_expires_at';
  end if;

  if has_function_privilege('anon','public.grant_planet_support_authorization(uuid,uuid,uuid,timestamptz)','EXECUTE')
     or has_function_privilege('public','public.grant_planet_support_authorization(uuid,uuid,uuid,timestamptz)','EXECUTE') then
    raise exception 'ACS-A: the client surface was widened (anon/public)';
  end if;

  if not has_function_privilege('authenticated','public.grant_planet_support_authorization(uuid,uuid,uuid,timestamptz)','EXECUTE') then
    raise exception 'ACS-A: authenticated lost EXECUTE';
  end if;

  if not has_function_privilege('service_role','public.grant_planet_support_authorization(uuid,uuid,uuid,timestamptz)','EXECUTE') then
    raise exception 'ACS-A: service_role lost EXECUTE';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.planet_support_authorizations'::regclass
      and conname='planet_support_authorizations_destination_guest_key'
      and contype='u'
  ) then
    raise exception 'ACS-A: the unique constraint targeted by the fix does not exist';
  end if;
end
$acs_a$;
