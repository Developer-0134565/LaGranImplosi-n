-- ============================================================================
-- MAKE public.complete_research IDEMPOTENT  (forward-only)
-- ----------------------------------------------------------------------------
-- FINDING (LIVE audit 2026-09-21): complete_research(queue_id) is correct for a
-- first completion (row FOR UPDATE, status/time guards, advisory lock, planet
-- settlement to finishes_at, absolute UPSERT of player_research.level, status
-- COMPLETED), but a SECOND call raised 'Research queue is not active'.
-- A retry or a concurrent double tick therefore produced a hard error instead of
-- a no-op.
--
-- FIX (smallest possible change): when the locked row is already COMPLETED,
-- return false without touching anything — no second settlement, no level change,
-- no timestamp/status mutation. Every other status keeps its previous behaviour:
--   * RESEARCHING but finishes_at > now()  -> still raises 'Research is not finished yet'
--   * CANCELLED / any other unexpected status -> still raises 'Research queue is not active'
--   * unknown queue id                      -> still raises 'Research queue does not exist'
-- Security posture is unchanged: still SECURITY INVOKER with search_path=public,pg_temp
-- and EXECUTE reserved for postgres/service_role (it is only called by the trusted
-- planet-tick / universe-heartbeat chain).
-- ============================================================================

create or replace function public.complete_research(p_queue_id uuid)
 returns boolean
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
 v_player_id uuid; v_planet_id uuid; v_universe_id uuid; v_research_id text; v_target_level integer; v_status text; v_finishes_at timestamptz; v_planet_id_iter uuid;
begin
 select player_id,planet_id,research_id,target_level,status,finishes_at into v_player_id,v_planet_id,v_research_id,v_target_level,v_status,v_finishes_at from public.research_queue where id=p_queue_id for update;
 if not found then raise exception 'Research queue does not exist: %',p_queue_id; end if;
 if upper(v_status) = 'COMPLETED' then
  return false;
 end if;
 if v_status<>'RESEARCHING' then raise exception 'Research queue is not active. Current status: %',v_status; end if;
 if v_finishes_at>now() then raise exception 'Research is not finished yet. Finishes at: %',v_finishes_at; end if;
 select universe_id into v_universe_id from public.players where id=v_player_id;
 if v_universe_id is null and v_planet_id is not null then select universe_id into v_universe_id from public.planets where id=v_planet_id; end if;
 if v_player_id is not null then perform pg_advisory_xact_lock(hashtextextended('planet-economy:'||v_player_id::text,0)); end if;
 for v_planet_id_iter in select p.id from public.planets p where p.player_id=v_player_id and (v_universe_id is null or p.universe_id=v_universe_id) and not p.is_destroyed order by p.id loop
  perform public.update_planet_resources_until_raw(v_planet_id_iter,v_finishes_at);
 end loop;
 insert into public.player_research(player_id,research_id,level) values(v_player_id,v_research_id,v_target_level) on conflict(player_id,research_id) do update set level=excluded.level;
 update public.research_queue set status='COMPLETED' where id=p_queue_id;
 return true;
end;
$function$;
