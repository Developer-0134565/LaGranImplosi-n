-- ============================================================================
-- HARDEN public.ui_defense_queue  (forward-only)   [finding C-01]
-- ----------------------------------------------------------------------------
-- DEFECT (confirmed against LIVE on 2026-09-20):
--   public.ui_defense_queue(p_player_id uuid, p_planet_id uuid)
--     SECURITY DEFINER, search_path = 'public' (no pg_temp)
--     ACL = { =X/postgres, postgres, service_role, anon, authenticated }  <- EXECUTE publico
--     body validated ONLY:  planets.id = p_planet_id
--                      AND  planets.player_id = p_player_id
--                      AND  NOT planets.is_destroyed
--   -> auth.uid() was never consulted. Any client holding only the publishable
--      key could read the defense_queue of ANY player by supplying that
--      player's UUID plus one of their planet UUIDs. Both UUIDs are publicly
--      derivable (planets_select_access is intentionally public, and
--      players_select_access exposes every AI player).
--   Origin: 20260915052725_add_guest_defense_queue_ui_reader.sql (guest UI reader).
--
-- WHY HARDEN INSTEAD OF DROP:
--   The repository has 0 consumers (only docs and the generated types), but the
--   currently DEPLOYED frontend revision is not verifiable from this session, so
--   dropping the contract could break an unobserved caller. The minimal correct
--   fix is therefore to keep the contract and remove the hole:
--     * search_path gains pg_temp (matches every other hardened entrypoint);
--     * the ownership predicate is rebased on auth.uid();
--     * EXECUTE is revoked from PUBLIC and anon, kept for authenticated.
--   An anonymous session (auth.signInAnonymously) still holds role
--   `authenticated`, so a legitimate owner is unaffected; a session-less caller
--   is now rejected.
--
-- Idempotent: CREATE OR REPLACE + REVOKE/GRANT are safe to re-run.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.ui_defense_queue(
  p_player_id uuid,
  p_planet_id uuid
)
RETURNS SETOF public.defense_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'AUTHENTICATION_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.planets p
    join public.players pl on pl.id = p.player_id
    where p.id = p_planet_id
      and p.player_id = p_player_id
      and p.is_destroyed = false
      and pl.user_id = auth.uid()
  ) then
    raise exception 'PLANET_ACCESS_DENIED';
  end if;

  return query
  select q.*
  from public.defense_queue q
  where q.planet_id = p_planet_id
    and q.status in ('BUILDING', 'QUEUED')
  order by q.finishes_at;
end;
$function$;

revoke all on function public.ui_defense_queue(uuid, uuid) from public;
revoke all on function public.ui_defense_queue(uuid, uuid) from anon;
grant execute on function public.ui_defense_queue(uuid, uuid) to authenticated;

COMMIT;
