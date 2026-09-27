-- FIX: prepare_expedition_resource_reward column/variable ambiguity — LA GRAN IMPLOSIÓN
-- --------------------------------------------------------------------------------------------
-- `prepare_expedition_resource_reward` returns TABLE(fleet_id, reward_tier, ...), so `fleet_id` is a
-- PL/pgSQL OUT variable. One statement referenced the bare column name:
--
--     UPDATE public.expedition_reward_budgets SET ... WHERE fleet_id=p_fleet_id;
--
-- which PL/pgSQL rejects at runtime with 42702 (column reference "fleet_id" is ambiguous). This is a
-- PRE-EXISTING latent defect: it sits on the EXPEDITION → RESOURCES outcome path, so that outcome
-- could never complete (the resolver raises before the reward is persisted).
--
-- Detected systematically: of every public function whose body contains an unqualified
-- `fleet_id = ...` reference, ONLY this one also declares `fleet_id` as an OUT parameter. The other
-- occurrences (create_expedition_reward_budget, resolve_expedition_*, prepare_expedition_ship_reward_*,
-- calculate_expedition_dark_matter_amount) do not declare that name, so they resolve to the column
-- normally and are deliberately NOT touched.
--
-- Forward-only, minimal fix: qualify the column with the table name. No behaviour change other than
-- the statement now executing. Same exact-match, EOL-canonicalised substitution technique.
DO $patch_budget$
DECLARE
    v_def text;
    v_old text;
    v_new text;
    v_occ integer;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'prepare_expedition_resource_reward';

    IF v_def IS NULL THEN
        RAISE EXCEPTION 'EXPEDITION-AMBIGUITY: prepare_expedition_resource_reward not found';
    END IF;

    v_old := $frag$UPDATE public.expedition_reward_budgets SET base_resource_find=v_base,max_resource_find=v_max_find,scaled_resource_find=v_scaled,resource_type=v_resource_type,final_resource_amount=v_final WHERE fleet_id=p_fleet_id;$frag$;

    v_new := $frag$UPDATE public.expedition_reward_budgets SET base_resource_find=v_base,max_resource_find=v_max_find,scaled_resource_find=v_scaled,resource_type=v_resource_type,final_resource_amount=v_final WHERE public.expedition_reward_budgets.fleet_id=p_fleet_id;$frag$;

    v_old := replace(replace(v_old, chr(13)||chr(10), chr(10)), chr(13), '');
    v_new := replace(replace(v_new, chr(13)||chr(10), chr(10)), chr(13), '');
    IF position(chr(13)||chr(10) in v_def) > 0 THEN
        v_old := replace(v_old, chr(10), chr(13)||chr(10));
        v_new := replace(v_new, chr(10), chr(13)||chr(10));
    END IF;

    SELECT (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) INTO v_occ;
    IF v_occ <> 1 THEN
        RAISE EXCEPTION 'EXPEDITION-AMBIGUITY: budget UPDATE fragment matched % time(s), expected 1', v_occ;
    END IF;

    EXECUTE replace(v_def, v_old, v_new);
END;
$patch_budget$;
