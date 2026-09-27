-- ACTIVE AI — ownership gates accept the declared AI actor (2026-09-26)
-- --------------------------------------------------------------------------------------------
-- Two minimal, asserted edits per gate, so the AI reuses the EXISTING dispatchers instead of a parallel path:
--   * `IF v_auth_user IS NULL THEN RAISE 'Authentication required'`  →  the same check plus
--     `AND NOT public.is_ai_actor_target(p_player_id)` (case-insensitive regexp, covers every wording variant);
--   * the dead guest branch `coalesce(pl.is_guest,false)`  →  `(coalesce(pl.is_guest,false) or
--     public.is_ai_actor_target(pl.id))` (fleet dispatchers).
-- A human session, an anonymous caller and an undeclared service context all keep failing exactly as before.
begin;

do $patch$
declare
    v_fn text;
    v_def text;
    v_new text;
    v_changed boolean;
begin
    foreach v_fn in array array['start_building', 'start_research', 'start_ship', 'start_defense',
                                 'start_support_fleet', 'start_fleet', 'start_fleet_mixed', 'start_colonize_fleet']
    loop
        select pg_get_functiondef(p.oid) into v_def
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = v_fn;

        if v_def is null then
            raise exception 'AI_GATE_PATCH: % not found', v_fn;
        end if;

        v_changed := false;

        v_new := regexp_replace(v_def, 'v_auth_user\s+IS\s+NULL\s+THEN',
            'v_auth_user IS NULL AND NOT public.is_ai_actor_target(p_player_id) THEN', 'gi');
        if v_new <> v_def then
            v_changed := true;
            v_def := v_new;
        end if;

        v_new := replace(v_def, 'coalesce(pl.is_guest,false)',
            '(coalesce(pl.is_guest,false) or public.is_ai_actor_target(pl.id))');
        if v_new <> v_def then
            v_changed := true;
            v_def := v_new;
        end if;

        if not v_changed then
            raise exception 'AI_GATE_PATCH: no gate fragment found in %', v_fn;
        end if;

        execute v_def;
    end loop;
end;
$patch$;

do $patch$
declare
    v_def text;
    v_new text;
begin
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'enforce_player_write_access';

    if v_def is null then
        raise exception 'AI_GATE_PATCH: enforce_player_write_access not found';
    end if;

    v_new := replace(v_def, 'if coalesce(v_is_guest, false) is not true then',
        'if public.is_ai_actor_target(v_player_id) then' || chr(10) ||
        '      /* declared AI worker acting for an AI player: allowed */' || chr(10) ||
        '      null;' || chr(10) ||
        '    elsif coalesce(v_is_guest, false) is not true then');

    if v_new = v_def then
        raise exception 'AI_GATE_PATCH: write-access guest branch not found';
    end if;

    execute v_new;
end;
$patch$;

comment on function public.start_building(uuid, uuid, text) is
$c$Starts a building for a player. Ownership: an authenticated caller must own the player (auth.uid() ->
players.user_id); a session-less caller is accepted only when it is a declared AI actor for that exact AI player
(`ai_actor_begin` + `is_ai_actor_target`). No gate was removed or weakened.$c$;

commit;
