-- =============================================================================
-- RECOVERED MIGRATION — 20260918095029
-- ledger name : fix_zero_level_drive_research_lookup
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================

create or replace function public.get_player_research_level(
  p_player_id uuid,
  p_research_id text
) returns integer
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select pr.level
    from public.player_research pr
    where pr.player_id = p_player_id
      and pr.research_id = p_research_id
    limit 1
  ), 0);
$$;
revoke execute on function public.get_player_research_level(uuid,text) from public, anon, authenticated;

