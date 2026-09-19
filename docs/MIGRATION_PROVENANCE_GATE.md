# Migration Provenance Gate — La Gran Implosión

> Operational guardrail for LIVE/LOCAL migration provenance. This document records known state; it does
> not reconstruct missing SQL and does not authorize deployment or migration-ledger changes.

## Current critical state

| Version | LOCAL | LIVE | Provenance | Status |
|---|---|---|---|---|
| `20260919100000_add_acs_hold_support_dispatch.sql` | YES | YES | known | APPLIED |
| `20260919101000_extend_acs_hold_worker_lifecycle.sql` | YES | YES | known | APPLIED |
| `20260919180000_fix_planet_support_authorization_ambiguity.sql` | YES | NO | known local file | **LOCAL_ONLY / NOT_DEPLOYED / BLOCKED** |
| `20260919055336` | NO | YES | **NOT_RECOVERABLE** | **LIVE_ONLY / NOT_RECOVERABLE / BLOCKED** |
| `20260919061454` | NO | YES | **NOT_RECOVERABLE** | **LIVE_ONLY / NOT_RECOVERABLE / BLOCKED** |
| `20260919062509` | NO | YES | **NOT_RECOVERABLE** | **LIVE_ONLY / NOT_RECOVERABLE / BLOCKED** |
| `20260919070020` | NO | YES | **NOT_RECOVERABLE** | **LIVE_ONLY / NOT_RECOVERABLE / BLOCKED** |

The four LIVE-only versions are confirmed unavailable from Git, branches, tags, reflog, stashes,
worktrees, backups, archives and the remote repository. Their SQL must not be inferred from the current
database schema or reconstructed from downstream state.

`20260919180000_fix_planet_support_authorization_ambiguity.sql` remains local and must not be deployed
while the unresolved LIVE-only provenance prevents a safe normal deployment path. The correction remains
`LOCAL_ONLY / NOT_DEPLOYED / BLOCKED` until the drift is resolved through valid provenance.

## Migration provenance rules

1. A LIVE migration whose payload cannot be recovered is classified as `LIVE_ONLY / NOT_RECOVERABLE`.
2. Never invent or reconstruct a lost migration from the current database state.
3. Never create a placeholder migration with the same version number.
4. Never mark a migration `reverted` solely to unblock `db push`.
5. Never manually edit the migration table or ledger to hide drift.
6. If the provenance required to continue deployment is unavailable, deployment is **BLOCKED**.
7. Do not run `supabase db push`, `supabase db query`, `supabase db query --file`, `migration repair`,
   reset or replay as a workaround for this gate.
8. Do not deploy `20260919180000_fix_planet_support_authorization_ambiguity.sql` while the four
   LIVE-only migrations remain unresolved.

## Operational lifecycle

```text
LOCAL_ONLY → DEPLOYED → VERIFIED
                  ↘
                BLOCKED
```

- `LOCAL_ONLY`: the migration exists in the repository but is not deployed.
- `DEPLOYED`: deployment is evidenced, but verification may still be pending.
- `VERIFIED`: deployment and resulting state have been explicitly verified.
- `BLOCKED`: a provenance, deployment or verification condition prevents advancing safely.

This gate is a stop condition, not a repair plan. Any future resolution requires explicit provenance
evidence and a forward-only, reviewed decision.

## Phase 1 provenance sweep — 2026-09-19

The primary-source search was completed without recovering any of the four LIVE-only payloads. The
read-only sweep covered:

- all local branches, remote-tracking branches, tags, reflogs, reachable history and unreachable Git
  objects;
- the canonical repository and the available quarantine, consolidation-backup and ZIP artifacts;
- exact version/name/content searches for each missing version;
- the official GitHub repository branches, tags, migration tree and exact code/commit searches.

The only exact textual hits are the current provenance statements in this document and
`PROJECT_CONTEXT_PROMPT.md`. Those references record the known status but are not migration payloads and
do not establish historical provenance. No version meets the recovery criterion of exact version +
exact payload + verifiable source. The four versions therefore remain:

```text
20260919055336 → LIVE_ONLY / NOT_RECOVERABLE / BLOCKED
20260919061454 → LIVE_ONLY / NOT_RECOVERABLE / BLOCKED
20260919062509 → LIVE_ONLY / NOT_RECOVERABLE / BLOCKED
20260919070020 → LIVE_ONLY / NOT_RECOVERABLE / BLOCKED
```
