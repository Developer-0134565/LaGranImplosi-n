-- =============================================================================
-- RECOVERED MIGRATION — 20260918085406
-- ledger name : 20260918110000_add_can_start_research_contract
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.can_research(
    p_player_id uuid, p_research_id text, p_target_level integer
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_current_level integer;
    v_max_level integer;
    v_missing_requirements integer;
BEGIN
    SELECT rd.max_level INTO v_max_level FROM public.research_definitions rd WHERE rd.id=p_research_id;
    IF NOT FOUND THEN RETURN false; END IF;
    IF v_max_level IS NOT NULL AND p_target_level>v_max_level THEN RETURN false; END IF;
    SELECT coalesce(pr.level,0) INTO v_current_level FROM public.player_research pr
    WHERE pr.player_id=p_player_id AND pr.research_id=p_research_id;
    v_current_level:=coalesce(v_current_level,0);
    IF p_target_level<>v_current_level+1 THEN RETURN false; END IF;
    SELECT count(*) INTO v_missing_requirements
    FROM public.research_prerequisites rp
    LEFT JOIN public.player_research pr ON pr.player_id=p_player_id AND pr.research_id=rp.prerequisite_research_id
    WHERE rp.research_id=p_research_id AND coalesce(pr.level,0)<rp.required_level;
    RETURN v_missing_requirements=0;
END;
$function$;

ALTER FUNCTION public.can_research(uuid,text,integer) OWNER TO postgres;

CREATE OR REPLACE FUNCTION public.can_start_research(
    p_player_id uuid, p_planet_id uuid, p_research_id text
)
RETURNS TABLE(
    allowed boolean, reason_code text, reason text,
    current_level integer, target_level integer,
    cost_metal numeric, cost_crystal numeric, cost_deuterium numeric,
    available_metal numeric, available_crystal numeric, available_deuterium numeric,
    research_seconds numeric, item_bonus_percent numeric,
    finishes_at_estimate timestamptz, prerequisites_met boolean,
    prerequisites jsonb, queue_available boolean, active_job jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public, pg_temp
AS $function$
DECLARE
    v_auth_user uuid:=auth.uid();
    v_player_universe uuid;
    v_planet_universe uuid;
    v_current_level integer:=0;
    v_target_level integer;
    v_max_level integer;
    v_cost record;
    v_research_time numeric:=0;
    v_item_bonus numeric:=0;
    v_metal numeric:=0;
    v_crystal numeric:=0;
    v_deuterium numeric:=0;
    v_prerequisites jsonb:='[]'::jsonb;
    v_prerequisites_met boolean:=true;
    v_active_job jsonb:=null;
BEGIN
    IF v_auth_user IS NULL THEN
        RETURN QUERY SELECT false,'AUTHENTICATION_REQUIRED','Authentication required',
          0,0,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,
          null::timestamptz,false,'[]'::jsonb,false,null::jsonb; RETURN;
    END IF;

    SELECT pl.universe_id INTO v_player_universe FROM public.players pl
    WHERE pl.id=p_player_id AND pl.user_id=v_auth_user;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false,'PLAYER_NOT_OWNED','Player does not belong to authenticated user',
          0,0,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,
          null::timestamptz,false,'[]'::jsonb,false,null::jsonb; RETURN;
    END IF;

    SELECT p.universe_id INTO v_planet_universe FROM public.planets p
    WHERE p.id=p_planet_id AND p.player_id=p_player_id AND p.is_destroyed=false;
    IF NOT FOUND OR v_planet_universe<>v_player_universe THEN
        RETURN QUERY SELECT false,'PLANET_NOT_FOUND_OR_NOT_OWNED',
          'Planet does not exist, is destroyed, or is not owned by the player',
          0,0,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,
          null::timestamptz,false,'[]'::jsonb,false,null::jsonb; RETURN;
    END IF;

    SELECT rd.max_level INTO v_max_level FROM public.research_definitions rd WHERE rd.id=p_research_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false,'RESEARCH_NOT_FOUND','Research definition not found',
          0,0,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,
          null::timestamptz,false,'[]'::jsonb,false,null::jsonb; RETURN;
    END IF;

    SELECT coalesce(pr.level,0) INTO v_current_level FROM public.player_research pr
    WHERE pr.player_id=p_player_id AND pr.research_id=p_research_id;
    v_current_level:=coalesce(v_current_level,0);
    v_target_level:=v_current_level+1;

    IF v_max_level IS NOT NULL AND v_target_level>v_max_level THEN
        RETURN QUERY SELECT false,'RESEARCH_MAX_LEVEL_REACHED','Research maximum level reached',
          v_current_level,v_target_level,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,
          0::numeric,0::numeric,null::timestamptz,false,'[]'::jsonb,true,null::jsonb; RETURN;
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'research_id',rp.prerequisite_research_id,
      'required_level',rp.required_level,
      'current_level',coalesce(pr.level,0),
      'satisfied',coalesce(pr.level,0)>=rp.required_level
    ) ORDER BY rp.prerequisite_research_id),'[]'::jsonb)
    INTO v_prerequisites
    FROM public.research_prerequisites rp
    LEFT JOIN public.player_research pr ON pr.player_id=p_player_id AND pr.research_id=rp.prerequisite_research_id
    WHERE rp.research_id=p_research_id;

    SELECT coalesce(bool_and(x.satisfied),true) INTO v_prerequisites_met
    FROM jsonb_to_recordset(v_prerequisites) AS x(satisfied boolean);

    SELECT jsonb_build_object(
      'id',q.id,'research_id',q.research_id,'target_level',q.target_level,
      'started_at',q.started_at,'finishes_at',q.finishes_at,'status',q.status
    ) INTO v_active_job
    FROM public.research_queue q
    WHERE q.player_id=p_player_id AND upper(q.status) IN ('RESEARCHING','QUEUED','ACTIVE')
    ORDER BY q.started_at NULLS LAST,q.id LIMIT 1;

    SELECT coalesce(pr.metal,0),coalesce(pr.crystal,0),coalesce(pr.deuterium,0)
    INTO v_metal,v_crystal,v_deuterium
    FROM public.planet_resources pr WHERE pr.planet_id=p_planet_id;

    SELECT c.metal,c.crystal,c.deuterium INTO v_cost
    FROM public.calculate_research_cost(p_research_id,v_target_level) c;

    SELECT crt.final_time_seconds INTO v_research_time
    FROM public.calculate_research_time(p_player_id,p_research_id,v_target_level) crt;

    v_item_bonus:=public.get_active_expedition_item_effect(p_player_id,p_planet_id,'research_speed_percent');
    v_research_time:=round(v_research_time/(1+v_item_bonus/100),4);

    IF NOT v_prerequisites_met THEN
        RETURN QUERY SELECT false,'RESEARCH_REQUIREMENTS_NOT_MET','Research prerequisites are not satisfied',
          v_current_level,v_target_level,v_cost.metal,v_cost.crystal,v_cost.deuterium,
          v_metal,v_crystal,v_deuterium,v_research_time,v_item_bonus,
          now()+(v_research_time*interval '1 second'),false,v_prerequisites,(v_active_job IS NULL),v_active_job; RETURN;
    END IF;

    IF v_active_job IS NOT NULL THEN
        RETURN QUERY SELECT false,'RESEARCH_QUEUE_ALREADY_ACTIVE','A research job is already active',
          v_current_level,v_target_level,v_cost.metal,v_cost.crystal,v_cost.deuterium,
          v_metal,v_crystal,v_deuterium,v_research_time,v_item_bonus,
          now()+(v_research_time*interval '1 second'),true,v_prerequisites,false,v_active_job; RETURN;
    END IF;

    IF v_metal<v_cost.metal OR v_crystal<v_cost.crystal OR v_deuterium<v_cost.deuterium THEN
        RETURN QUERY SELECT false,'INSUFFICIENT_RESOURCES','Insufficient resources',
          v_current_level,v_target_level,v_cost.metal,v_cost.crystal,v_cost.deuterium,
          v_metal,v_crystal,v_deuterium,v_research_time,v_item_bonus,
          now()+(v_research_time*interval '1 second'),true,v_prerequisites,true,null::jsonb; RETURN;
    END IF;

    RETURN QUERY SELECT true,'OK','Research can be started',
      v_current_level,v_target_level,v_cost.metal,v_cost.crystal,v_cost.deuterium,
      v_metal,v_crystal,v_deuterium,v_research_time,v_item_bonus,
      now()+(v_research_time*interval '1 second'),true,v_prerequisites,true,null::jsonb;
END;
$function$;

ALTER FUNCTION public.can_start_research(uuid,uuid,text) OWNER TO postgres;

REVOKE EXECUTE ON FUNCTION public.can_start_research(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_start_research(uuid,uuid,text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.can_research(uuid,text,integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.check_research_requirements(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_research_requirements(uuid,text) FROM PUBLIC, anon, authenticated;
