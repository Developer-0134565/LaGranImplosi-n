# Production DB baseline / source-of-truth audit

> Status: AUDIT ARTIFACT — 2026-09-14
>
> This document deliberately does **not** pretend that the Git migration directory is a complete reconstruction of production.

## Current production snapshot

Supabase project: `evtfsbntvuqmahiskekd`

- Applied migrations: **215**
- First applied migration: `20260912092555`
- Last applied migration: `20260914215616`
- Public tables: **58**
- Public functions: **212**
- Public indexes: **171**
- Public RLS policies: **58**
- Public base tables with RLS enabled: **58 / 58**

## Repository state

The repository currently contains the recent hardening/evolution migrations, including the final security migrations, but it does not contain the historical 215-migration chain.

Therefore:

1. Production is the authoritative live database for the current game.
2. The repository is the authoritative source for application code and the migrations currently checked in.
3. A clean Supabase project cannot yet be guaranteed to reproduce the current production schema from `supabase/migrations` alone.
4. We must **not** fabricate hundreds of historical migrations or perform destructive production changes merely to make the migration count match.

## Security state verified during final audit

All 58 public tables currently have RLS enabled and one policy each.

The final security hardening removed direct client mutation access to internal state and queue processors. Canonical game APIs remain exposed only where they are intended to be client entrypoints.

## Required closure step

Create a safe, reproducible **production schema baseline** from the live database, including:

- tables and columns
- types/enums
- primary/foreign/check/unique constraints
- indexes
- RLS policies
- grants/default privileges
- functions and their definitions
- triggers
- relevant extensions/configuration

The baseline must be captured without modifying gameplay data. After it exists, a clean test database must be built from the baseline and the checked-in post-baseline migrations must be replayed against it.

## Do not do

- Do not delete or reset production data.
- Do not renumber existing migration versions.
- Do not invent historical migrations from memory.
- Do not mark missing historical migrations as applied in a new database without an actual equivalent schema baseline.

## Exit criterion

The DB ↔ GitHub audit becomes **GREEN** when a clean database can reproduce the production schema and the current checked-in migrations can be applied deterministically on top of that baseline.
