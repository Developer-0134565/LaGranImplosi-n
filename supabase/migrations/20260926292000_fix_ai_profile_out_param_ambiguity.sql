-- ============================================================================
-- FIX — ai_ensure_player_profile OUT-parameter ambiguity (forward-only)
-- ----------------------------------------------------------------------------
-- 20260926290000_ai_behaviour_model created ai_ensure_player_profile with an OUT parameter named
-- `player_id`, which collides with ai_player_profiles.player_id inside its own INSERT:
--
--   ERROR 42702: column reference "player_id" is ambiguous
--
-- The policy hits that on the first evaluation of any AI player without a stored profile, i.e. always.
-- Forward-only fix: the OUT parameter is renamed to `out_player_id` (the convention the AI worker already
-- uses). Nothing else changes: same argument, same row count, same columns except that rename, and the
-- only consumer (ai_decide_and_act) reads the profile by column name (`personality`, `budget_percent`,
-- `last_action_at`, `last_action_kind`, `next_action_at`), all of which are untouched.
-- ============================================================================

drop function if exists public.ai_ensure_player_profile(uuid);

create or replace function public.ai_ensure_player_profile(p_player_id uuid)
returns table(out_player_id uuid, personality text, budget_percent numeric, last_action_at timestamptz,
              last_action_kind text, next_action_at timestamptz)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_is_ai boolean;
    v_personality text;
begin
    if p_player_id is null then
        raise exception 'AI_PROFILE_PLAYER_REQUIRED';
    end if;

    select (pl.player_type = 'AI' and pl.user_id is null) into v_is_ai
      from public.players pl where pl.id = p_player_id;
    if coalesce(v_is_ai, false) is not true then
        raise exception 'AI_PROFILE_TARGET_NOT_AI: %', p_player_id;
    end if;

    select app.personality into v_personality
      from public.ai_player_profiles app where app.player_id = p_player_id;

    if v_personality is null then
        v_personality := (array['INDUSTRIAL','SCIENTIST','MILITARY','PREDATOR'])
                         [1 + floor(public.ai_hash_unit(p_player_id::text || '|personality', 5) * 4)::integer];
        insert into public.ai_player_profiles (player_id, personality)
        values (p_player_id, v_personality)
        on conflict (player_id) do nothing;
    end if;

    return query
    select app.player_id, app.personality, app.budget_percent, app.last_action_at, app.last_action_kind,
           app.next_action_at
      from public.ai_player_profiles app
     where app.player_id = p_player_id;
end;
$function$;

revoke all on function public.ai_ensure_player_profile(uuid) from public, anon, authenticated;
grant execute on function public.ai_ensure_player_profile(uuid) to service_role;