# MESSAGING ENGINE — LA GRAN IMPLOSIÓN

> The player's central event inbox: the producer contract, the message set, replay safety, ACL and tests.
> Operational status: [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md). Related:
> [`README_ESPIONAGE_ENGINE.md`](README_ESPIONAGE_ENGINE.md), [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md),
> [`README_COMBAT_ENGINE.md`](README_COMBAT_ENGINE.md), [`README_RANKING.md`](README_RANKING.md).

## 1. State (2026-09-26)

```text
BEFORE   `player_messages` existed with a hardened ACL (`20260926091605`), an owner-scoped read contract and an
         idempotent mark-as-read (`20260926095835`), but ZERO producers: the table could never receive a row.
AFTER    migration `20260926120000_messaging_engine` + `20260926120010_messaging_event_producers` (LIVE): every
         relevant gameplay event produces a message, produced by triggers on the tables the engine already writes.
         No certified engine function was modified.
```

## 2. Authority

| Object | Role | ACL |
|---|---|---|
| `player_messages.dedupe_key` (new column + partial unique index) | producer-side idempotency stamp | internal |
| `create_player_message(recipient, sender, subject, body, dedupe_key)` | the ONLY write path | `postgres`/`service_role` only |
| `format_coordinates(g, s, p)` | read-only body helper | `postgres`/`service_role` only |
| `get_player_messages(limit, unread_only)` | inbox read contract (already existed) | `authenticated`/`service_role`, never `anon` |
| `mark_message_read(message_id)` | idempotent mark-as-read (already existed) | `authenticated`/`service_role`, never `anon` |

The recipient is never a client parameter: each producer takes it from the row the engine already wrote
(`fleet_movements.player_id`, `planets.player_id`, `expedition_results.player_id`, `combat_battle_participants.player_id`).

## 3. Message set (OGameX `app/GameMessages` parity)

```text
producer trigger                                  event                                   recipient
notify_fleet_status_change   (AFTER UPDATE OF status on fleet_movements)
   OUTBOUND → ARRIVED        "Fleet arrived"                                         fleet owner
   → HOLDING                 "Fleet holding"                                         fleet owner
   → RETURNING               "Fleet returning" / "Debris field harvested" (RECYCLE)  fleet owner
   → COMPLETED               "Fleet returned"                                        fleet owner
notify_combat_participant    (AFTER INSERT on combat_battle_participants)
   ATTACKER/ATTACK           "Battle report" (pointer to combat_battles)             attack initiator
   DEFENDER/PLANET|FLEET     "Battle report" + "Attack received" (ATTACK only)       defender
   DEFENDER/ENEMY            (NPC side, no player) → nothing
notify_expedition_result     (AFTER INSERT on expedition_results)
                             "Expedition report: <outcome>"                          expedition owner
notify_colony_established    (AFTER INSERT on planets)
                             "Colony established"                                    colony owner (not homeworlds)
resolve_espionage_arrival    (explicit producers, see README_ESPIONAGE_ENGINE)
                             "Espionage report", "Fleet lost contact",
                             "You were espied"                                       attacker / defender
```

Messages are **pointers**, not copies: the payload keeps living in `espionage_reports`, `combat_battles`,
`expedition_results` — exactly the design the previous block left open ("no dupliques informes que ya tienen un
sistema específico").

## 4. Safety properties

```text
REPLAY SAFE   a non-null dedupe_key (e.g. 'fleet_returning:<fleet id>', 'battle_report:<battle id>',
              'colony:<planet id>', 'espionage_detected:<fleet id>') makes production idempotent: the same event
              produced twice inserts one row (partial unique index + ON CONFLICT DO NOTHING). NULL keys stay
              unlimited so manual mail is never deduplicated.
NON-BLOCKING  every trigger body runs inside its own exception handler and only raises a WARNING
              (MESSAGE_PRODUCER_FAILED ...), so a messaging failure can never abort fleet resolution, a combat
              settlement or an economy update.
OWNERSHIP     no producer accepts a recipient from outside; ownership comes from the row the engine wrote.
```

## 5. Tests

```text
supabase/tests/fleet_recall.sql         assertion 3: the recall transition produced the "fleet returning" message
supabase/tests/counter_espionage.sql    assertion 10: espionage report + fleet lost contact + you were espied +
                                        defender battle report (4/4)
LIMITATION  both fixtures are single-session harnesses; concurrent production is not executed.
```

## 6. GAPS

```text
* No message retention/purge job (OGameX `DeleteOldMessages`): OUT OF SCOPE for this block.
* No unread-count contract (a UI can filter with `get_player_messages(..., p_unread_only => true)`).
* Buildings/research contents are still not part of an espionage report, so no message references them.
* `src/GameplayEnginePanel.tsx` renders the inbox; the generated `database.types.ts` had to gain the new function
  signatures by hand (the CLI regeneration needs credentials that this environment does not have).
```

## Message and espionage retention (2026-09-26)

`20260926200000_message_retention_worker.sql` implements the OGameX scheduled cleanup
(`app/Console/Commands/Scheduler/DeleteOldMessages.php`, `RETENTION_DAYS = 7`, chunked deletion of 1000 rows):

* `purge_old_player_messages(keep_days default 7, batch default 1000)` and
  `purge_old_espionage_reports(keep_days default 7, batch default 1000)` delete inbox documents strictly by age
  (`created_at <= now() - keep_days`) in batches of 1000, exactly like OGameX. Ownership is untouched: rows are
  deleted, never rewritten, and read/unread documents expire alike.
* `run_message_retention_worker(keep_days default 7, batch default 1000)` runs both purges and returns the
  counts. ACL is `service_role` only (the client never triggers retention), so the worker can not be abused to
  wipe another player inbox.
* Scheduling: pg_cron job `lagranimplosion-message-retention` daily at 04:00, following the project convention
  (`lagranimplosion-ranking-refresh` → `select public.run_ranking_worker();`). The window is a parameter, so the
  product can change it without a schema change.
* OGameX also archives `ChatMessage`: LGI has no chat subsystem, so that branch has no equivalent (documented).

Tests: `supabase/tests/message_retention_worker.sql` — **7 PASS + 1 INFO, LIVE 2026-09-26**: OGameX defaults
kept, old documents expire while recent ones survive, idempotent second run, window honoured (30 days keeps
8-day-old rows), batched purge of 1501 old rows with batch 1000, invalid window refused, ACL and the cron job.
Transactional with ROLLBACK. LIMITATION: the cron tick is asserted statically and the espionage branch could not
be seeded when the player owns no fleet to satisfy `espionage_reports.fleet_id` (NOT NULL + FK); the purge was
still evaluated on that path.

## Integration audit 2026-09-26 — Supabase ↔ frontend

Static + LIVE cross-check of every contract the React client consumes. Two broken wires were found and fixed.

### Fixed 1 — the message centre read a table the RLS denies (P1)

`src/App.tsx` built the SPYING/ESPIONAJE section of the message list with a **direct table read**:

```text
before: supabase.from('espionage_reports').select('id,player_id,espionage_level,...').eq('player_id',playerId)
after:  rpcUntyped('get_player_espionage_reports', { p_limit: 25 })
```

`public.espionage_reports` carries the policy `deny_direct_api_access`, so the direct read returned **zero rows with
no error** — the section was silently empty for every player. Proven LIVE: as an authenticated actor the direct
`select` returns 0 rows while the certified RPC is the only read path. The RPC also keeps the ownership chain
(`auth.uid()` → `players.id`), so the client no longer needs to pass a `player_id` at all. The panel now maps the
`out_*` columns (`out_report_id`, `out_espionage_level`, `out_target_espionage_level`, `out_metal`, `out_crystal`,
`out_deuterium`, `out_created_at`) that the contract declares.

### Fixed 2 — `database.types.ts` was 8 contracts behind LIVE (P3)

The file was regenerated from the real schema only for the missing entries (no invented types):
`can_start_demolition`, `start_demolition`, `get_player_expedition_item_status`, `get_player_expedition_reports`,
`get_player_expedition_slot_status`, `get_universe_evolution_monitor_public`, `get_universe_ranking_by_category`,
`provision_player`. After the patch `npx tsc -b` and `npm run build` are clean and every RPC the frontend calls is
now typed (the explicit casts can be removed in a future cleanup, they remain harmless).

### Verified connected (LIVE, as the authenticated actor)

* `get_universe_ranking_by_category(universe,'GENERAL'|'ECONOMY'|'RESEARCH'|'MILITARY',10)` → 10 rows per category with
  `out_rank/out_username/out_player_type/out_points/out_is_current_player` (the actor is flagged `me=t`).
* `get_universe_evolution_monitor_public(universe)` → 1 row with the 29 columns the monitor lib reads.
* `start_demolition` / `can_start_demolition` as a **foreign** authenticated actor → refused with
  `PLAYER_NOT_OWNED_BY_AUTH_USER` (`start_demolition` is protected transitively by `inspect_demolition`, which is the
  certified actor gate; it has no gate of its own, which is why the refusal comes from the inspector).
* Direct reads the client performs (`planets`, `planet_buildings`, `planet_ships`, `building_queue`,
  `research_queue`, `shipyard_queue`, `defense_queue`, `planet_defenses`, `player_research`, `fleet_movements`,
  `universe_galaxies`, the `*_definitions` tables) are RLS-filtered: as a foreign actor `planet_buildings` of
  another player returns 0 rows.

### Reported, not changed (needs an owner decision)

* **CLOSED 2026-09-26** — the `can_start_building` oracle (P2) was fixed by
  `20260926240000_harden_can_start_building_ownership.sql`: the certified name is now `SECURITY DEFINER` with the
  identity gate (authentication → ownership → declared AI actor) returning `AUTHENTICATION_REQUIRED` /
  `PLAYER_NOT_OWNED` as a blocked row, and the original evaluation logic lives on verbatim as
  `evaluate_building_start_internal` (service_role only). See `docs/systems/README_ECONOMY.md` for the full record.
* **INFO** — every other function in `public` (306 total) is deliberately backend-only: cron workers, combat
  internals, AI policy, service-role helpers (`authenticated:false` in their ACL). No frontend caller invokes them.
