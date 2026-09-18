-- =============================================================================
-- RECOVERED MIGRATION — 20260918095315
-- ledger name : deduplicate_fleet_event_indexes
-- provenance  : Supabase LIVE supabase_migrations.schema_migrations.statements
--               (verbatim payload of the original apply_migration call; no historical
--                local file existed in this repository, its stashes or the local copies)
-- recovered   : 2026-09-18 by the drift-reconciliation mission
-- ALREADY APPLIED IN LIVE — do not re-apply; this file exists for traceability only.
-- =============================================================================
drop index if exists public.idx_fleet_movements_outbound_arrival; drop index if exists public.idx_fleet_movements_returning;
