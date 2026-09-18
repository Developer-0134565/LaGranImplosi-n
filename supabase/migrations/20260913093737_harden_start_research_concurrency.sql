BEGIN;

CREATE OR REPLACE FUNCTION public.start_research(p_player_id uuid, p_planet_id uuid, p_research_id text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_universe_id uuid;
    v_current_level integer;
    v_target_level integer;
    v_research_time numeric;
    v_metal_cost numeric;
    v_crystal_cost numeric;
    v_deuterium_cost numeric;
    v_queue_id uuid;
    v_item_bonus numeric := 0;
    v_auth_user uuid;
BEGIN
    v_auth_user := auth.uid();

    IF v_auth_user IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND pl.user_id = v_auth_user
    ) THEN
        RAISE EXCEPTION 'Player does not belong to authenticated user';
    END IF;

    IF v_auth_user IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.players pl
        WHERE pl.id = p_player_id
          AND coalesce(pl.is_guest, false) = true
    ) THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    -- Research is player-wide, not planet-wide. Lock the player row so two
    -- simultaneous requests cannot both pass the single research-queue check.
    PERFORM 1 FROM public.players WHERE id = p_player_id FOR UPDATE;

    SELECT universe_id INTO v_universe_id
    FROM public.planets
    WHERE id = p_planet_id AND player_id = p_player_id AND is_destroyed = false
    FOR UPDATE;

    IF v_universe_id IS NULL THEN
        RAISE EXCEPTION 'PLANET_NOT_FOUND_OR_NOT_OWNED';
    END IF;

    IF NOT EXISTS(SELECT 1 FROM public.research_definitions WHERE id=p_research_id) THEN
        RAISE EXCEPTION 'RESEARCH_NOT_FOUND: %',p_research_id;
    END IF;

    SELECT COALESCE(MAX(level),0) INTO v_current_level
    FROM public.player_research
    WHERE player_id=p_player_id AND research_id=p_research_id;
    v_target_level:=v_current_level+1;

    IF EXISTS(SELECT 1 FROM public.research_definitions WHERE id=p_research_id AND max_level IS NOT NULL AND v_target_level>max_level) THEN
        RAISE EXCEPTION 'RESEARCH_MAX_LEVEL_REACHED';
    END IF;

    IF EXISTS(SELECT 1 FROM public.research_queue WHERE player_id=p_player_id AND UPPER(status) IN('RESEARCHING','QUEUED','ACTIVE')) THEN
        RAISE EXCEPTION 'RESEARCH_QUEUE_ALREADY_ACTIVE';
    END IF;

    SELECT c.metal,c.crystal,c.deuterium INTO v_metal_cost,v_crystal_cost,v_deuterium_cost
    FROM public.calculate_research_cost(p_research_id,v_target_level) c;
    v_research_time:=public.calculate_research_time(p_research_id,v_target_level,v_universe_id);
    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);
    PERFORM public.update_planet_resources(p_planet_id);
    PERFORM 1 FROM public.planet_resources WHERE planet_id=p_planet_id FOR UPDATE;
    UPDATE public.planet_resources
    SET metal=metal-v_metal_cost,crystal=crystal-v_crystal_cost,deuterium=deuterium-v_deuterium_cost,updated_at=now()
    WHERE planet_id=p_planet_id AND metal>=v_metal_cost AND crystal>=v_crystal_cost AND deuterium>=v_deuterium_cost;
    IF NOT FOUND THEN RAISE EXCEPTION 'INSUFFICIENT_RESOURCES'; END IF;

    INSERT INTO public.research_queue(player_id,planet_id,research_id,target_level,started_at,finishes_at,status)
    VALUES(p_player_id,p_planet_id,p_research_id,v_target_level,now(),now()+(v_research_time*interval '1 second'),'RESEARCHING')
    RETURNING id INTO v_queue_id;
    RETURN v_queue_id;
END;
$function$;

COMMIT;
