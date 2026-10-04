-- ============================================================================================
-- OWNER-SCOPED READ CONTRACT — the caller's OWN beginner protection state
-- ============================================================================================
-- GAP (2026-09-28, small gameplay gap cycle). Beginner protection is a real, ENFORCED gameplay rule:
-- `enforce_beginner_protection_before_insert` refuses any ATTACK whose target sits inside its first 24 h
-- with `TARGET_BEGINNER_PROTECTED`. Verified LIVE: attacking a freshly created empire raises
--     TARGET_BEGINNER_PROTECTED: player <id> is protected until <ts>
--
-- But the player had NO way to know it. `get_player_attack_protection(player_id, at)` is `service_role`
-- only, and no `src/` file referenced protection at all, so the only place the rule surfaced was the raw
-- exception text of a FAILED attack. An attacker never learns they are protected, and the protected
-- player never learns they are shielded. In OGame this state is plainly visible to the player.
--
-- This contract is read-only and answers exactly one question: is MY empire inside the protection
-- window, and until when. It follows the same pattern as the certified Messages read contracts
-- (get_player_transport_movements / get_player_battle_reports):
--   * ownership resolved strictly through auth.uid() -> players.user_id -> players.id. NO player_id
--     argument, so no argument can read another player's state;
--   * SECURITY DEFINER with a pinned search_path;
--   * ACL: authenticated + service_role, never anon;
--   * the rule itself is NOT re-implemented here: it delegates to the existing
--     `get_player_attack_protection`, which remains the single authority, so the UI can never drift
--     from the trigger that enforces it.
--
-- Deliberately NOT changed: the trigger, the protection window, the AI scope, the ACL of the existing
-- service_role helper (which stays service_role only), and any other system.
-- ============================================================================================

create or replace function public.get_my_attack_protection()
returns table(
    out_protected boolean,
    out_protected_until timestamptz,
    out_reason text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
    select p.out_protected, p.out_protected_until, p.out_reason
    from public.players pl
    cross join lateral public.get_player_attack_protection(pl.id) p
    where pl.user_id = auth.uid();
$fn$;

comment on function public.get_my_attack_protection() is
$c$Client read contract for the caller's OWN beginner-protection state (is my empire attackable?).
Ownership is resolved strictly through auth.uid() -> players.user_id -> players.id, so there is no
player_id argument and no argument can select another player. The rule is NOT re-implemented: this
delegates to get_player_attack_protection, the same authority the ATTACK insert trigger uses, so the UI
can never drift from the enforcement. SECURITY DEFINER with a pinned search_path. Read-only.$c$;

-- ACL: the same shape as the other Messages read contracts — authenticated + service_role, never anon.
revoke all on function public.get_my_attack_protection() from public;
revoke all on function public.get_my_attack_protection() from anon;
grant execute on function public.get_my_attack_protection() to authenticated;
grant execute on function public.get_my_attack_protection() to service_role;

-- Post-conditions: the ACL is what we claim, the contract takes no player selector, and it did not
-- weaken the service_role-only helper it delegates to.
do $verify$
declare
    v_bad text;
begin
    if has_function_privilege('anon', 'public.get_my_attack_protection()', 'EXECUTE')
       or not has_function_privilege('authenticated', 'public.get_my_attack_protection()', 'EXECUTE')
       or not has_function_privilege('service_role', 'public.get_my_attack_protection()', 'EXECUTE') then
        raise exception 'MY_ATTACK_PROTECTION_CONTRACT: ACL drift after creation';
    end if;

    -- no player selector may creep in
    select string_agg(a, ', ') into v_bad
      from unnest(regexp_split_to_array(
             (select p.prosrc::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'get_my_attack_protection'), '\s+')) a
     where a ilike '%p_player_id%';
    if v_bad is not null then
        raise exception 'MY_ATTACK_PROTECTION_CONTRACT: must not take a player selector (%s)', v_bad;
    end if;

    -- the internal helper must stay service_role only
    if has_function_privilege('authenticated', 'public.get_player_attack_protection(uuid,timestamp with time zone)', 'EXECUTE') then
        raise exception 'MY_ATTACK_PROTECTION_CONTRACT: the internal helper was opened to authenticated';
    end if;
end;
$verify$;
