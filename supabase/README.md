# Supabase database migrations

The live project contains a large migration history that predates the current Git repository. The repository currently records the post-audit hardening migrations applied on 2026-09-13:

- `20260913043259_harden_api_security_and_indexes.sql`
- `20260913043318_harden_lifeform_mutations_and_fix_legacy_combat.sql`
- `20260913043356_lock_down_public_default_privileges.sql`
- `20260913044000_harden_internal_rpc_permissions.sql`

The live database also contains the follow-up migration `20260913044032_harden_game_action_auth_guards`. It hardens the exposed `start_*` SECURITY DEFINER game-action functions so authenticated callers cannot substitute another player's ID, while preserving the existing anonymous guest-access model. Its complete historical function bodies are currently retained in the live schema rather than reconstructed blindly into the repository because the repository still lacks the earlier migration chain that those functions depend on.

Do **not** reset or recreate the production database from this directory yet. The complete historical migration chain still needs to be reconstructed from the live project before a clean-from-zero deployment can be considered reproducible.

The internal RPC hardening only removes direct Data API execution from functions that are implementation details. The `start_*` RPCs remain exposed intentionally because they are the current game action entrypoints; their writes are protected by the player-access trigger layer and the action-level auth guards.

These migrations are intentionally incremental and safe to reapply only through the normal Supabase migration mechanism; they should not be manually duplicated in SQL Editor.
