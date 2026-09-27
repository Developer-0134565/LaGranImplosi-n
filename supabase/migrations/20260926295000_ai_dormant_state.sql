-- ============================================================================
-- AI DORMANT STATE — LGI (2026-09-26)
-- ----------------------------------------------------------------------------
-- The owner-approved policy of 20260926291000 makes an AI act like a player, but every AI must be born
-- DORMANT: a new AI receives a normal player's initial state and then waits for an explicit activation (a
-- future product decision). DORMANT is therefore a PERSISTENT, explicit state — not an inference from
-- `last_action_at IS NULL`, empty resources, empty buildings, a magic date or any other heuristic.
--
--   ai_player_profiles.status  text NOT NULL DEFAULT 'DORMANT' CHECK (status IN ('DORMANT','ACTIVE'))
--
-- DORMANT affects ONLY the AI policy. It does not touch the economy engine: an AI planet keeps receiving the
-- same production/queue/worker ticks a human would receive (no player_type filter exists in those workers).
--
-- Enforcement is double:
--   1. the policy entry point becomes a gate: it reads the persistent status and returns
--      (none, null, 'AI_DORMANT') before any evaluation, so a DORMANT AI never consumes budget, never
--      reaches a certified dispatcher and never even runs the policy body;
--   2. the worker only walks ACTIVE players, so a dormant population costs nothing per tick.
--
-- The certified policy body itself is preserved byte-for-byte: it is renamed to `ai_decide_and_act_core` and
-- EXECUTE is revoked from every role, so the gate is the only reachable entry point (definer owner access).
--
-- Activation seam (deliberately NOT a new API): a service-role statement
--   UPDATE public.ai_player_profiles SET status = 'ACTIVE' WHERE player_id = <uuid>;
-- or the reverse to put an AI back to sleep. No client-facing RPC is created, no activation is performed here
-- and no AI is activated by this migration (all existing profiles stay DORMANT via the column default).
-- ============================================================================

alter table public.ai_player_profiles
    add column if not exists status text not null default 'DORMANT';

do $status_check$
begin
    if not exists (select 1
                     from pg_constraint c
                     join pg_class t on t.oid = c.conrelid
                     join pg_namespace n on n.oid = t.relnamespace
                    where n.nspname = 'public' and t.relname = 'ai_player_profiles'
                      and c.conname = 'ai_player_profiles_status_check') then
        alter table public.ai_player_profiles
            add constraint ai_player_profiles_status_check check (status in ('DORMANT', 'ACTIVE'));
    end if;
end;
$status_check$;

-- ---------------------------------------------------------------------------
-- 1. Gate: the policy body is preserved, but only reachable through the state check
-- ---------------------------------------------------------------------------
do $rename_core$
begin
    if exists (select 1 from pg_proc p
                where p.pronamespace = 'public'::regnamespace and p.proname = 'ai_decide_and_act'
                  and pg_get_function_identity_arguments(p.oid) = 'p_player_id uuid, p_budget_percent numeric, p_at timestamp with time zone') then
        execute 'alter function public.ai_decide_and_act(uuid, numeric, timestamptz) rename to ai_decide_and_act_core';
    end if;
end;
$rename_core$;

revoke all on function public.ai_decide_and_act_core(uuid, numeric, timestamptz) from public, anon, authenticated, service_role;

create or replace function public.ai_decide_and_act(p_player_id uuid,
                                                    p_budget_percent numeric default 60,
                                                    p_at timestamptz default null)
returns table(action text, target text, result text)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_status text;
begin
    /* DORMANT is a persistent state, not a heuristic. A missing profile is DORMANT by definition. */
    select app.status into v_status
      from public.ai_player_profiles app
     where app.player_id = p_player_id;

    if coalesce(v_status, 'DORMANT') <> 'ACTIVE' then
        action := 'none'; target := null; result := 'AI_DORMANT';
        return next; return;
    end if;

    return query
    select * from public.ai_decide_and_act_core(p_player_id, p_budget_percent, p_at);
end;
$function$;

revoke all on function public.ai_decide_and_act(uuid, numeric, timestamptz) from public, anon, authenticated;
grant execute on function public.ai_decide_and_act(uuid, numeric, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Worker: ACTIVE players only, round-robin mechanism preserved
-- ---------------------------------------------------------------------------
create or replace function public.run_ai_policy_worker(p_max_players integer default 25,
                                                       p_budget_percent numeric default 60,
                                                       p_at timestamptz default null)
returns table(out_player_id uuid, out_action text, out_target text, out_result text)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_player record;
    v_decision record;
    v_at timestamptz := coalesce(p_at, now());
    v_total integer;
    v_offset integer;
begin
    if p_max_players is null or p_max_players < 1 then
        raise exception 'AI_WORKER_LIMIT_INVALID: %', p_max_players;
    end if;

    /* population = ACTIVE AI players of active universes; DORMANT AI players are skipped entirely
       (the 20260926294000 round-robin is preserved: it now rotates over the ACTIVE population) */
    select count(*) into v_total
      from public.players pl
      join public.universes u on u.id = pl.universe_id and u.is_active
      join public.ai_player_profiles app on app.player_id = pl.id and app.status = 'ACTIVE'
     where pl.player_type = 'AI' and pl.user_id is null
       and exists (select 1 from public.planets p
                    where p.player_id = pl.id and p.kind = 'PLANET' and p.is_destroyed = false);

    if coalesce(v_total, 0) = 0 then
        return;   /* a fully dormant population costs nothing per tick */
    end if;

    /* deterministic round-robin: one p_max_players slice per 5-minute tick */
    v_offset := ((floor(extract(epoch from (v_at at time zone 'utc')) / 300)::bigint * p_max_players)
                 % v_total)::integer;

    for v_player in
        select pl.id
        from public.players pl
        join public.universes u on u.id = pl.universe_id and u.is_active
        join public.ai_player_profiles app on app.player_id = pl.id and app.status = 'ACTIVE'
        where pl.player_type = 'AI' and pl.user_id is null
          and exists (select 1 from public.planets p
                       where p.player_id = pl.id and p.kind = 'PLANET' and p.is_destroyed = false)
        order by pl.last_activity_at nulls first, pl.created_at, pl.id
        limit p_max_players offset v_offset
    loop
        out_player_id := v_player.id;
        out_action := 'none';
        out_target := null;
        out_result := 'AI_PENDING';

        perform public.ai_actor_begin(v_player.id);
        begin
            select * into v_decision from public.ai_decide_and_act(v_player.id, p_budget_percent, p_at);
            out_action := coalesce(v_decision.action, 'none');
            out_target := v_decision.target;
            out_result := coalesce(v_decision.result, 'AI_NO_DECISION');
        exception when others then
            out_action := 'none';
            out_target := null;
            out_result := 'AI_ERROR: ' || sqlerrm;
        end;
        perform public.ai_actor_end();

        return next;
    end loop;
end;
$function$;

revoke all on function public.run_ai_policy_worker(integer, numeric, timestamptz) from public, anon, authenticated;
grant execute on function public.run_ai_policy_worker(integer, numeric, timestamptz) to service_role;