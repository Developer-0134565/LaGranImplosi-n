# Supabase database migrations

The live project contains a large migration history that predates the current Git repository. The repository currently records the post-audit hardening migrations applied on 2026-09-13:

- `20260913043259_harden_api_security_and_indexes.sql`
- `20260913043318_harden_lifeform_mutations_and_fix_legacy_combat.sql`
- `20260913043356_lock_down_public_default_privileges.sql`

Do **not** reset or recreate the production database from this directory yet. The complete historical migration chain still needs to be reconstructed from the live project before a clean-from-zero deployment can be considered reproducible.

These migrations are intentionally incremental and safe to reapply only through the normal Supabase migration mechanism; they should not be manually duplicated in SQL Editor.
