# OWNERSHIP HARDENING — LA GRAN IMPLOSIÓN

## Status

**CLOSED / VERIFIED LIVE — 2026-09-18**

Ownership hardening closes the direct player/planet ownership boundary for the six critical client-facing game-action/state entrypoints identified by the audit.

## Hardened RPCs

The live migration `20260918030000_harden_player_ownership_in_owned_rpcs` is applied to the production Supabase project.

| RPC | Scope |
|---|---|
| `start_building(uuid, uuid, text)` | player + planet |
| `start_research(uuid, uuid, text)` | player + planet |
| `start_ship(uuid, uuid, text, bigint)` | player + planet |
| `start_defense(uuid, uuid, text, bigint)` | player + planet |
| `start_fleet(uuid, uuid, uuid, text, bigint, text)` | player + origin/destination |
| `sync_current_planet_resources(uuid, uuid, timestamptz)` | player + planet |

All six are currently `SECURITY DEFINER` and explicitly set `search_path = public, pg_temp`.

## Authorization contract

The hardened entrypoints enforce the supplied player against the authenticated user:

```text
players.id = p_player_id
AND players.user_id = auth.uid()
```

Planet-scoped entrypoints additionally require:

```text
planets.id = p_planet_id
AND planets.player_id = p_player_id
AND planets.is_destroyed = false
```

Unauthenticated execution is rejected.

## Live verification

### Foreign-player test

A transaction impersonating a different authenticated user attempted all six RPCs against a planet owned by another player.

Result:

```text
foreign_owner_rejection_passed
```

All six calls were rejected by the ownership guard and the transaction was rolled back.

### NULL-auth test

A transaction executed as `authenticated` with no JWT subject attempted all six RPCs.

Result:

```text
null_auth_rejection_passed
```

All six calls rejected the unauthenticated request. No mutation was committed.

### ACL note

`start_fleet` currently has no `anon` EXECUTE privilege while the other five hardened entrypoints retain `anon` EXECUTE. This is an ACL difference, not an ownership bypass: the ownership tests still reject unauthenticated requests, and the final security/RLS phase may review the remaining public ACL surface separately.

## Security boundary

The purpose of this migration is to prevent a caller from supplying another player's UUID while invoking a privileged `SECURITY DEFINER` function.

This is distinct from:

- gameplay validation;
- RLS policy completeness;
- final public EXECUTE ACL cleanup;
- internal RPC exposure;
- queue correctness;
- formula correctness.

Those remain separate audit dimensions.

## Reproducibility finding

The migration is confirmed in LIVE Supabase migration history, but the expected checked-in path

```text
supabase/migrations/20260918030000_harden_player_ownership_in_owned_rpcs.sql
```

was not present in the current GitHub default branch during this audit.

Therefore:

- **LIVE state:** verified and CLOSED;
- **repository migration traceability:** OPEN finding.

Do not recreate or alter the live database merely to solve this documentation/reproducibility gap. The next repository-maintenance step should recover the exact migration source (or an equivalent checked-in migration representation) from the authoritative development history before treating repository parity as closed.

## Conclusion

Ownership hardening itself is **CLOSED / VERIFIED LIVE**.

The only remaining ownership-related finding is **repository migration traceability**, not a demonstrated live authorization defect.
