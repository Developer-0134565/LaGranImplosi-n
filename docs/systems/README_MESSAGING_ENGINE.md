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

## 7. Battle-report detail view — CLOSED 2026-09-28

### 7.1 The hole (measured, not assumed)

The communications centre grouped every event into four categories and each category had a real owner panel
EXCEPT the combat one: the COMBATE row of `renderMessages()` (`src/App.tsx`) was a single summary string — outcome, loot, own
loss totals, debris and the round COUNT. The contract `get_player_battle_reports` has always returned two more columns
that the browser never read:

```text
rounds       [{round, attacker_units_before, attacker_units_after, defender_units_before,
                         defender_units_after, defender_combat_units_after}]   <- per-round unit counts
participants [{side, participant_type, player_id, fleet_id, planet_id}]             <- who took part
```

So the player could read THAT a battle happened and that it lasted N rounds, but never WHAT happened in any
of them, nor which bodies fought. The whole point of a battle report (OGameX `BattleReport`, rendered as a
round-by-round table) was missing, while the data was already persisted, already owner-scoped and already
ACL-safe. `README_COMBAT_ENGINE.md` §17 had listed the «battle-report screen» as a UI mission over this very
contract; the contract was done, the screen was not.

### 7.2 What was implemented (UI only)

```text
panel        BattleReportsPanel (src/GameplayEnginePanel.tsx), mounted by the Messages view in src/App.tsx
read path    get_player_battle_reports(p_limit 25) — the ONLY read path; no new RPC, no second architecture
renders      per battle: outcome label from the server `outcome` + `caller_role`, loot, debris,
             ships before->after, defenses before->after, round count, finish time
             per battle (expandable): participants, own losses named with ui_ship_definitions /
             ui_defense_definitions, and ONE ROW PER ROUND with the four unit counters
authority    the panel never derives a combat value: every number is the contract's own answer. Unit names come
             from the certified definition contracts and an unknown id is printed as-is (never invented)
patterns     reuses the existing neo-panel / neo-list-panel / neo-list-row / status-pill / neo-button classes
             and the same fetch-then-render shape as EspionageReportsPanel; no global CSS touched
no new CSS   the round rows reuse the same nested neo-list-panel, so the UI Designer's stylesheet is untouched
```

### 7.3 Verification

```text
supabase/tests/battle_report_ui_contract.sql — 8 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  the owner retrieves the whole payload: ATTACKER_WIN, role ATTACKER, 2 rounds, 2 participants, 2 loss rows
  2  round-by-round unit counts are exposed EXACTLY as stored (10->8 / 4->2 then 8->6 / 2->0)
  3  participants are exposed (attacker FLEET + defender PLANET)
  4  losses are exposed for both sides (light_fighter x2 ATTACKER, rocket_launcher x3 DEFENDER)
  5  a foreign authenticated player reads 0 rows of that battle
  6  without a session the battle is invisible
  7  ACL unchanged: authenticated + service_role, anon denied
  8  an unfinished battle is UNRESOLVED, not a win
  INFO  the panel is READ-ONLY, so the fixture proves the CONTRACT payload and the ownership chain it
        renders, not a browser render
regression   supabase/tests/owner_read_contracts.sql re-checked LIVE — 8 PASS (inbox, mark-as-read, foreign
             refusal, espionage limit clamp, ACL boundary, no client write path); npx tsc -b exit 0;
             npx vite build exit 0; git diff --check clean
browser      ENVIRONMENT BLOCKED — no browser driver + human DEV credential in this environment.
             The panel's rendering is therefore NOT certified; only the contract it consumes is.
```

Scope note: the COMBATE summary row of `renderMessages()` was left exactly as it is. It is a category
aggregate, not a defect, and the new panel is the detail surface for the same contract.

Follow-ups reported, NOT changed (owner decisions, outside this mission):
* The four category tabs still have no unread state: `MessageRow` in the communications centre has no read
  marker, because those rows are DERIVED from report contracts and `read_at` only exists on `player_messages`.
  Making a report "unread" needs a product decision on what it means for a derived report.
* TRANSPORTES read `fleet_movements` directly from the browser. CLOSED by §8 below (2026-09-28).

## 8. TRANSPORTES owner-scoped read contract — CLOSED 2026-09-28

### 8.1 The hole

The communications centre builds four categories. Three of them were served by a certified owner-scoped
contract (`get_player_battle_reports`, `get_player_espionage_reports`, `get_player_expedition_reports`).
TRANSPORTES was the last one reading a table straight from the browser:

```text
supabase.from('fleet_movements').select(…).eq('player_id', playerId).eq('mission_type','TRANSPORT')
  .order('created_at', {ascending:false}).limit(25)
```

This was **NOT a vulnerability**: `fleet_movements_select_access` is already owner-scoped
(`EXISTS … pl.user_id = auth.uid()`), so the client parameter could never widen access. It was an
architectural hole: the only Messages category where the BROWSER supplied its own ownership selector and
bypassed a server contract.

### 8.2 The contract

`20260928131919_add_player_transport_movements_read_contract.sql` (LIVE) adds exactly one function and
nothing else — no new table, no write path, no RLS change, no change to the fleet engine or to how fleets
move. It follows the pattern of its three siblings.

```text
name        public.get_player_transport_movements(p_limit integer default 25)
ownership   auth.uid() -> players.user_id -> players.id -> fleet_movements.player_id
            NO player_id argument: no argument can select another player's movements
mission     fixed to 'TRANSPORT' inside the body: the client cannot ask for other missions
limit       greatest(1, least(coalesce(p_limit, 25), 100)) — clamped server-side, never trusting the UI
order       created_at desc, id — identical to the .order('created_at', {ascending:false}) the browser applied
columns     out_movement_id, out_status, out_destination_galaxy/system/position, out_created_at
            exactly the six values the TRANSPORTES row renders; nothing copied "just in case"
security    SECURITY DEFINER + search_path pinned to public, pg_temp (fleet_movements carries RLS)
ACL         revoke public + anon; grant authenticated + service_role — the sibling contract shape
```

The migration also carries post-conditions: it raises if the ACL drifts, and raises if the contract ever
grows a `p_player_id` selector.

### 8.3 Frontend integration

`loadMessages()` (`src/App.tsx`) now resolves the category through the same `Promise.all` as its three
siblings and maps the `out_*` columns to the same `MessageRow`. Identical text, identical timestamp
(`out_created_at`), identical category, identical final `rows.sort` by `created_at` desc. `database.types.ts`
gained the function signature by hand (the CLI regeneration needs credentials this environment does not have).
No CSS, no layout, no other category, and none of the four report panels were touched.

`src/FleetCommandPanel.tsx` still reads `fleet_movements` directly, and that is correct and out of scope: it
is the Fleet dispatch screen, which needs the engine's own full row (ships, fuel, cargo, arrival times), not
the six columns a report row renders.

### 8.4 Verification

```text
supabase/tests/transport_movement_read_contract.sql — 12 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  the owner reads its own transport: id, status and the three destination coordinates
  2  an ATTACK movement of the same owner is NOT in the category (the mission filter is server-side)
  3  a foreign authenticated player reads 0 rows of that transport
  4  without a session the contract returns 0 rows
  5  the ONLY argument is p_limit — no player selector can be supplied by the client
  6  p_limit = 1 returns exactly 1 row
  7  ordering is created_at desc: the newest transport comes first
  8  p_limit = 5000 is clamped to the 100 ceiling
  9  a non-positive p_limit is clamped up to the 1 floor, never to zero
  10 no write path: SECURITY DEFINER read-only body
  11 ACL: authenticated + service_role, anon denied
  12 PARITY: the contract returns EXACTLY the rows the old direct read returned (0 differing)
  INFO single-session harness; concurrency not executed. The assertion is the CONTRACT, not a browser render.
residue    0: fleet_movements 0 rows, players 637, auth.users 12, TmtForeign 0 — identical to pre-run
regression the four sibling Messages contracts still callable, the fleet_movements SELECT policy still
           present, anon still denied — 7 PASS, 0 failures
static     npx tsc -b exit 0 · npx vite build exit 0 (both environments, 188 modules) · git diff --check clean
browser    ENVIRONMENT BLOCKED — no browser driver + human DEV credential in this environment. The visible
           category is therefore NOT certified in a browser; the contract behind it is.
OGameX     code search of lanedirt/OGameX requires an authenticated GitHub session, so no structural
           reference could be retrieved. The LGI contract pattern (the existing siblings) governed the design.
```

Limitations, stated rather than hidden:
* Browser validation is blocked; the parity assertion covers the data, not the DOM.
* LIVE carries no transport rows, so every behavioural assertion runs against rows the fixture creates and
  rolls back. The contract's behaviour on a player with many movements is asserted only up to the 100 clamp.
* The fixture had to work around two real properties of the environment, both of them expected authorities:
  the first system of LIVE is full (15/15), so the foreign homeworld coordinate is searched rather than
  hard-coded; and `enforce_player_write_access()` refuses to create a movement for a player the caller does
  not own, so the foreign transport is written as the foreign session.
* `fleet_movements.created_at` defaults to `now()`, which is constant inside a transaction; the fixture

## 9. Expedition combat detail (enemy fleet + losses) — CLOSED 2026-09-28

### 9.1 The gap (category B: backend without a consumer)

The expedition cycle was verified complete end to end and was **not** touched: dispatch →
`resolve_expedition_arrival` / `_pirates` / `_aliens` / `_black_hole` / `_item` / `_merchant` →
`expedition_results` → `get_player_expedition_reports` → `ExpeditionReportsPanel` + `ExpeditionMerchantPanel`.

The gap was narrower. `get_player_expedition_reports` returns 28 columns, two of which had **no consumer at
all** in `src/`:

```text
enemy_ships   jsonb   the fleet that actually fought the expedition (PIRATES / ALIENS)
lost_ships    jsonb   the ships the expedition destroyed or lost
```

`expeditionDetail()` printed the literal word `combate` when `battle_id` was set and nothing else. So a
pirate encounter told the player that a fight happened, never **who they fought** and never **what they
lost** — while the server had persisted and exposed both, owner-scoped and ACL-safe. This is the same
shape as the Battle Report UI gap closed in §7: backend complete and certified, consumer missing.

Measured LIVE (rolled back) before changing anything, driving the **real** `resolve_expedition_pirates`:

```text
resolve_expedition_pirates → battle 7aad5ee1…, result ATTACKER_WIN, enemy_ships {"light_fighter": 8}
get_player_expedition_reports(25) → enemy_ships {"light_fighter": 8}   ← returned to the client…
expeditionDetail()              → "combate"                            ← …and the panel ignored it
```

### 9.2 What changed (UI only)

`expeditionDetail()` in `src/GameplayEnginePanel.tsx` now renders both maps verbatim, alongside the
existing "combate" token:

```text
rival light_fighter×8
perdidas light_fighter×3
```

Ship ids are printed as the contract returns them, exactly like the sibling panels do (an unknown id is
never renamed or invented). The `ExpeditionReportRow` local type gained the two fields — the generated
`database.types.ts` already declared them. No CSS, no new component, no new RPC, no migration, and the
panel still decides nothing: it renders what the contract says.

### 9.3 Verification

```text
supabase/tests/expedition_combat_detail.sql — 11 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  the REAL pirate resolver produced a battle (ATTACKER_WIN)
  2  the contract exposes the enemy fleet: enemy_ships = {"light_fighter": 9}   <- the gap, proven
  3  lost_ships is an object or null (null is legitimate when nothing was lost)
  4  the report links to the battle it came from
  5  a real loss is reported verbatim (lost_ships = {"light_fighter": 3}, loss_percentage = 30)
  5b another authenticated player reads 0 rows of that expedition
  6  without a session the contract returns 0 rows
  7  p_limit = 0 is clamped to 1, so the panel still gets a row
  8  ACL unchanged: authenticated + service_role, anon denied
  9  the expedition engine was NOT modified by this mission
  10 the contract still exposes both columns
residue    0: expedition_results 0, fleet_movements 0, combat_battles 0, auth.users 12

## 10. Expedition cargo-clamp visibility — CLOSED 2026-09-28 (UI only)

### 10.1 The gap (a silent loss, not a missing cosmetic)

The expedition engine computes the reward as a clamp:

```text
calculate_expedition_resource_budget:
    v_tier_amount := v_base * v_multiplier;
    v_final       := LEAST(v_tier_amount, v_cargo);   -- "Una expedición no puede traer más
                                                        --  recursos que la capacidad efectiva de carga"
calculate_expedition_resource_amount_for_type: LEAST(cargo_capacity, scaled × 1 | 2/3 | 1/3)
```

When the find exceeded the fleet's hold the difference was **discarded silently**, and the report showed
only the award. The player could not distinguish "the expedition found nothing" from "the expedition found
plenty and my cargo was too small" — while the contract had been returning both sides of the clamp all
along (`scaled_resource_find`, `cargo_capacity`) with no consumer.

This was a product decision, taken explicitly: expose the *clamp result*, keep the *formula* private.

### 10.2 What changed

`expeditionDetail()` now renders one extra fragment, and ONLY when the clamp actually bit:

```text
encontrado 23107 · carga 100 · 23007 no cabía, se transportó el máximo
```

```text
if (hold > 0 && found > hold) parts.push(`encontrado ${found} · carga ${hold} · ${found - hold} no cabía, …`)
```

Both numbers come straight from the contract; the panel subtracts nothing it did not receive and
recomputes no reward. The `ExpeditionReportRow` local type gained the two fields (the generated
`database.types.ts` already declared them). No CSS, no new component, no RPC, no migration.

### 10.3 Deliberately NOT exposed (recorded so it is not re-litigated)

| Field | Decision | Why |
|---|---|---|
| `reward_tier` | hidden | SMALL/MEDIUM/LARGE bucket behind the internal roll; a restatement of the formula, and the persisted value (`NORMAL`) does not even match that vocabulary. |
| `reward_multiplier` | hidden | Pure formula input ("×1.4" tells the player nothing actionable and leaks tuning). |
| `max_resource_find` | hidden | Intermediate pre-multiplier roll; meaningless alone. |
| `scaled_resource_find` | shown **only** paired with `cargo_capacity` | Valuable solely as the pre-clamp figure whose loss must be explained. |
| `cargo_capacity` | shown | It is the clamp's denominator and a property of the player's own fleet — actionable ("send more cargo"). |
| `loot_applied_at` | out of scope | It is **not an expedition field**: it lives on `combat_battles` and is the idempotency guard written by `apply_attack_loot`. Settlement bookkeeping, not loot information. |

### 10.4 Verification

```text
supabase/tests/expedition_reward_visibility.sql — 10 PASS + 2 INFO, LIVE, ROLLBACK, residue 0
  1  the REAL engine produced a RESOURCES result (real dispatch + real resolver, retried until the
     random outcome roll landed on RESOURCES; nothing forced, nothing mocked)
  2  CLAMPED: the contract exposes found=23107 hold=100
  3  both clamp values are returned VERBATIM (stored == contract)
  4  UNCLAMPED: found=500 hold=25000 (no extra line)
  5  a zero-hold row reports 0 and the panel guard (hold > 0) suppresses the line
  6  another authenticated player reads 0 rows
  7  without a session the contract returns 0 rows
  8  ACL unchanged: authenticated + service_role, anon denied
  9  the expedition engine was NOT modified (no presentation text leaked into SQL)
  10 the LEAST(tier_amount, cargo) clamp formula is unchanged
residue    0: expedition_results 0, expedition_reward_budgets 0, fleet_movements 0, combat_battles 0,
           auth.users 12
regression 6 PASS: five expedition resolvers intact; merchant / items / slot contracts callable; the
           combat resolver + repair function intact; all previous missions' contracts callable; the
           espionage guard and the protection trigger survive; expedition_results still closed
static     npx tsc -b exit 0 · npx vite build exit 0 · git diff --check clean
browser    ENVIRONMENT BLOCKED — no browser driver + human DEV credential. The contract is certified;
           the rendering is not.
```

### 10.5 Limitations

* Browser validation is blocked; the panel is READ-ONLY, so the assertions cover the contract payload.
* The outcome roll is genuinely random, so the fixture repeats the real flow until RESOURCES rather than
  forcing a branch. Between attempts it pulls `planet_resources.last_calculated_at` back to `now()`
  because resolving a fleet advances it past the current instant; the engine's own
  `INVALID_RESOURCE_TIMESTAMP` guard is respected, not bypassed, and only bookkeeping is touched.
* The visible line explains a loss caused **only** by cargo capacity. No formula, economy, capacity or
  reward value was changed.

regression 5 PASS: all five expedition resolvers still exist; merchant + item contracts callable;
           the espionage / battle / transport / protection / debris contracts all still callable; the
           espionage composition guard and the beginner-protection trigger survive; expedition_results
           still closed to direct client access
static     npx tsc -b exit 0 · npx vite build exit 0 · git diff --check clean
browser    ENVIRONMENT BLOCKED — no browser driver + human DEV credential. The panel is READ-ONLY, so
           the contract it consumes is certified while its rendering is not.
```

### 9.4 Limitations, stated rather than hidden

* Browser validation is blocked; the assertions cover the contract payload and its ownership, not the DOM.
* LIVE carries zero `expedition_results`, so both the pirate fixture and the real-render check run against
  rows the fixture creates and rolls back.
* `reward_tier`, `reward_multiplier`, `max_resource_find`, `scaled_resource_find` and `cargo_capacity` are
  also unconsumed, but they are **scoring internals of the reward formula**, not a player-facing fact the
  player is missing. Surfacing them would be a presentation product decision, so they were deliberately
  left alone and recorded as the next candidate.
* This adds rendering only. The expedition engine, its probabilities, rewards, resolvers, worker and ACL
  are untouched.

  therefore sets it explicitly, otherwise the `created_at desc, id` order is decided by a random uuid.


## 11. A false "Colony established" message on every moon formation — CLOSED 2026-09-29

### 11.1 The gap (a false statement about game state, category A: producer body)

`trg_notify_colony_established` is `AFTER INSERT ON public.planets` — and `public.planets` holds
**both** bodies: a colony is `kind = 'PLANET'`, a moon is `kind = 'MOON'`. The producer's only guard was

```sql
if new.player_id is null or coalesce(new.is_homeworld, false) then return new; end if;
```

`settle_moon_creation_for_battle` inserts the moon with the **defender's** `player_id`,
`is_homeworld = false` and `kind = 'MOON'`, so it passed the guard. The defender therefore received
**two** messages, because the same function already announces the moon itself:

| producer | subject | body |
|---|---|---|
| `settle_moon_creation_for_battle` | `Moon formed` | "The debris of the battle at […] collapsed into a moon of N km." |
| `trg_notify_colony_established` | `Colony established` | "**Your colony ship founded** Moon at [1:2:3]." |

The second asserts an event that never happened: a colony ship was never involved, no colony was
founded, and the body is a moon. The inbox is the player's authoritative record of what the engine
did, so a fabricated entry there is a correctness defect, not a cosmetic one.

**Latent, not active.** LIVE held `656 PLANET / 0 MOON` rows at the time of the sweep, and **0**
`colony:` messages, so no false message had been produced yet. The defect is proven by the two live
function bodies and by the fixture, which drives a REAL moon insert.

### 11.2 The fix

`20260929000000_fix_colony_message_for_moon_bodies.sql` — one additional `kind` guard in the
producer body:

```sql
if new.kind is distinct from 'PLANET' then return new; end if;
```

The colony path is byte-for-byte unchanged for `kind = 'PLANET'`, and nothing is lost because the
moon already has its own producer. This is the same `kind` discrimination the project already uses
in `enforce_planet_kind_consistency`, `settle_moon_creation_for_battle` and `resolve_colonize_arrival`.

The migration is self-verifying (`do $verify$` raises on drift): the guard must be present, the
trigger must still be attached, `settle_moon_creation_for_battle` must still say `Moon formed`, no
producer may delegate to the colony trigger, and `create_player_message` must keep its ACL.

### 11.3 Verification

```text
supabase/tests/colony_message_body_kind.sql — 10 PASS / 0 FAIL, LIVE, ROLLBACK, residue 0
  1  a REAL MOON insert (kind='MOON', parent set, enforce_planet_kind_consistency exercised)
     produces 0 "Colony established" messages                              <- the regression
  2  a REAL PLANET insert still produces exactly one, verbatim:
     "Colony established" / "Your colony ship founded ColonyOfTheFixture at [1:39:1]."
  3  the moon row is a real MOON child of the defended planet
  4  a homeworld address never carries a colony message
  5  THE INVARIANT: 0 colony messages addressing a non-PLANET body
  6  create_player_message ACL: anon=f authenticated=f service_role=t
  7  the producer stays SECURITY DEFINER with a pinned search_path
  8  the trigger is still attached (the fix is in the body, not a detached trigger)
  9  settle_moon_creation_for_battle still announces the moon
  10 no pre-existing false colony message in the environment (the defect was latent)

regression (positive path, REAL dispatcher + REAL resolver) — 4 PASS / 0 FAIL, LIVE, ROLLBACK
  1  start_colonize_fleet    -> fleet created
  2  resolve_colonize_arrival -> colony created
  3  the colony message is still produced by the REAL path
  4  the created body is a PLANET colony

residue 0 after both runs: planets 656, moons 0, player_messages 6, players 656,
        planet_resources 656, auth.users 12 — identical to the pre-run state
untouched settle_moon_creation_for_battle, create_player_message, the trigger binding,
        resolve_colonize_arrival, the colony engine and every other producer
```

### 11.4 Not changed

The moon engine, the combat/moon chance formulas, the colony cap, the messaging ACL, the retention
worker, and every other producer. Browser validation is blocked in this environment (no driver plus
a human DEV credential), so what is certified is the contract and its effect on `player_messages`,
not the DOM.
