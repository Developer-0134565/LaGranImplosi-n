# OWNERSHIP HARDENING — LA GRAN IMPLOSIÓN

## Status

**CLOSED / VERIFIED LIVE — 2026-09-18**

Ownership hardening closes the direct player/planet ownership boundary for the six critical entrypoints changed by the hardening migration, while the broader audit also verified four additional SECURITY DEFINER `start_*` entrypoints already contained equivalent ownership guards.

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

### Extended ownership audit

The broader `SECURITY DEFINER` `start_*` surface was also inspected. Four additional entrypoints already contain ownership guards and were verified with the same foreign-player transactional test:

- `start_colonize_fleet(uuid, uuid, integer, integer, integer)`
- `start_fleet_mixed(uuid, uuid, uuid, jsonb, text)`
- `start_lifeform_building(uuid, text)`
- `start_lifeform_research(uuid, text)`

Result:

```text
extended_foreign_owner_rejection_passed
```

These four were not part of the six-function ownership migration because the live definitions already enforce the player resolved from the supplied planet against `auth.uid()` (or the guest path where applicable).

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
