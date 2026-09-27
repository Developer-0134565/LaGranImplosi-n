-- ACTIVE AI — explicit service-actor contract (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- The problem: every authoritative dispatcher derives its actor from `auth.uid()`, and an AI player has no session
-- (`players.user_id is null`, `player_type = 'AI'`), so it can never act — while the old guest branch that used to
-- allow session-less writes is dead (guests were removed) and must NOT be reopened.
--
-- The model implemented here, per the accepted rule "service actor → validate AI player ownership/state → invoke the
-- authoritative mechanic":
--   `ai_actor_begin(ai_player_id)`  declares the execution context. It is reachable only from a service context
--       (no session AND not a client role), it requires the target to be an ACTIVE-universe AI player with no
--       session owner, and it stores the declaration in the transaction-local settings `lgi.ai_worker` / `lgi.ai_player`.
--   `is_ai_actor_target(player)`    the ONLY thing the ownership gates ask: true when there is no session, the role
--       is not `authenticated`/`anon`, the AI context was declared, and it was declared FOR THIS PLAYER. A human
--       session, an anonymous caller, a stray definer function or a different player can never satisfy it.
--   `ai_actor_end()`                clears the declaration.
-- Nothing else changes: the dispatchers keep their `auth.uid()` ownership check, the queues keep
-- `enforce_player_write_access`, and a client can never impersonate anybody.
begin;

create or replace function public.is_ai_actor_target(p_player_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_role text;
begin
    if p_player_id is null then
        return false;
    end if;

    /* a real session is never an AI actor */
    if auth.uid() is not null then
        return false;
    end if;

    v_role := coalesce(auth.role(), '');
    if v_role in ('authenticated', 'anon') then
        return false;
    end if;

    /* the AI context must have been declared explicitly, and for this very player */
    if coalesce(current_setting('lgi.ai_worker', true), '') <> 'on' then
        return false;
    end if;
    if coalesce(current_setting('lgi.ai_player', true), '') <> p_player_id::text then
        return false;
    end if;

    return exists (select 1
                     from public.players pl
                    where pl.id = p_player_id
                      and pl.player_type = 'AI'
                      and pl.user_id is null);
end;
$function$;

comment on function public.is_ai_actor_target(uuid) is
$c$True only for an explicitly declared AI execution context (no session, non-client role, `lgi.ai_worker = 'on'` set by
`ai_actor_begin` for this exact player, and the player is an AI player without a session owner). Used by the ownership
gates so an AI can act through the same authoritative mechanics as a human without weakening any gate.$c$;

create or replace function public.ai_actor_begin(p_ai_player_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_type text;
    v_user uuid;
    v_universe uuid;
begin
    if auth.uid() is not null or coalesce(auth.role(), '') in ('authenticated', 'anon') then
        raise exception 'AI_ACTOR_REQUIRES_SERVICE_CONTEXT';
    end if;

    if p_ai_player_id is null then
        raise exception 'AI_ACTOR_PLAYER_REQUIRED';
    end if;

    select pl.player_type, pl.user_id, pl.universe_id
      into v_type, v_user, v_universe
      from public.players pl
     where pl.id = p_ai_player_id;

    if v_type is null then
        raise exception 'AI_ACTOR_PLAYER_NOT_FOUND: %', p_ai_player_id;
    end if;
    if v_type <> 'AI' then
        raise exception 'AI_ACTOR_TARGET_NOT_AI: %', p_ai_player_id;
    end if;
    if v_user is not null then
        raise exception 'AI_ACTOR_TARGET_HAS_SESSION_OWNER: %', p_ai_player_id;
    end if;
    if not exists (select 1 from public.universes u where u.id = v_universe and u.is_active) then
        raise exception 'AI_ACTOR_UNIVERSE_INACTIVE: %', v_universe;
    end if;

    perform set_config('lgi.ai_worker', 'on', true);
    perform set_config('lgi.ai_player', p_ai_player_id::text, true);

    return p_ai_player_id;
end;
$function$;

comment on function public.ai_actor_begin(uuid) is
$c$Declares the AI execution context for the current transaction after validating, server-side, that the target is an AI
player of an ACTIVE universe with no session owner. Callable only from a service context (no session, non-client role);
EXECUTE is granted to service_role only. The declaration is transaction-local, so it cannot leak between requests.$c$;

create or replace function public.ai_actor_end()
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    perform set_config('lgi.ai_worker', '', true);
    perform set_config('lgi.ai_player', '', true);
end;
$function$;

comment on function public.ai_actor_end() is
$c$Clears the AI execution context declared by `ai_actor_begin` (transaction-local).$c$;

revoke all on function public.is_ai_actor_target(uuid) from public, anon, authenticated;
grant execute on function public.is_ai_actor_target(uuid) to service_role;
revoke all on function public.ai_actor_begin(uuid) from public, anon, authenticated;
grant execute on function public.ai_actor_begin(uuid) to service_role;
revoke all on function public.ai_actor_end() from public, anon, authenticated;
grant execute on function public.ai_actor_end() to service_role;

commit;
