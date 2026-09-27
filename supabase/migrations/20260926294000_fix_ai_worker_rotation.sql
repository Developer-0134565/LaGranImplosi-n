-- ============================================================================
-- FIX — AI worker population rotation (forward-only)
-- ----------------------------------------------------------------------------
-- 20260926291000's worker selected the AI players with
--
--   order by pl.last_activity_at nulls first, pl.created_at
--   limit p_max_players
--
-- but `players.last_activity_at` is only written when the AI ACTS (ai_decide_and_act updates it on success).
-- A tick that lands outside an activity window, or that scores nothing, leaves the ordering untouched, so the
-- SAME first 25 of 586 AI players were re-evaluated every 5 minutes while the rest were never reached. The daily
-- windows of those 561 players would never be evaluated at all, which defeats the policy for most of the
-- population.
--
-- Forward-only fix: the batch window advances one `p_max_players` slice every 5 minutes (a deterministic
-- round-robin over the same population query), so the whole population is visited in
-- ceil(total / p_max_players) ticks (~2 h for 586 players) and every player is evaluated several times inside its
-- 3–6 h window. The rotation is derived from `coalesce(p_at, now())`, so it is testable: two instants five
-- minutes apart select different slices. Nothing else changes (same ordering inside the slice, same isolation,
-- same actor contract).
-- ============================================================================

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

    select count(*) into v_total
      from public.players pl
      join public.universes u on u.id = pl.universe_id and u.is_active
     where pl.player_type = 'AI' and pl.user_id is null
       and exists (select 1 from public.planets p
                    where p.player_id = pl.id and p.kind = 'PLANET' and p.is_destroyed = false);

    if coalesce(v_total, 0) = 0 then
        return;
    end if;

    /* deterministic round-robin: one p_max_players slice per 5-minute tick */
    v_offset := ((floor(extract(epoch from (v_at at time zone 'utc')) / 300)::bigint * p_max_players)
                 % v_total)::integer;

    for v_player in
        select pl.id
        from public.players pl
        join public.universes u on u.id = pl.universe_id and u.is_active
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