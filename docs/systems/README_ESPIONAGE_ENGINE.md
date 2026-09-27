# ESPIONAGE ENGINE — LA GRAN IMPLOSIÓN

> State, authority, contracts, lifecycle, the verified OGameX counter-espionage formula and its dependency gap.
> Operational status: [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md). Related:
> [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md) (the ESPIONAGE mission),
> [`README_COMBAT_ENGINE.md`](README_COMBAT_ENGINE.md) (the engine a counter-espionage battle would need),
> [`README_RESEARCH.md`](README_RESEARCH.md) (`espionage_technology`).

## 1. State (2026-09-27)

> Current operational entry point: **§9** (counter-espionage, implemented) and **§10** (evidence sweep 2026-09-27:
> level gating re-certified, the reveal outcome exposed to the client, the cross-owner read oracles closed and the
> engine-settle regression fixed). §1 describes the ORIGINAL 2026-09-26 state and is kept for history.

```text
EXISTS      mission ESPIONAGE end-to-end: start_fleet → OUTBOUND → resolve_espionage_arrival →
            espionage_reports row → RETURNING → probes back at the origin planet.
WORKS       yes. The arrival settles the target planet to the arrival instant (resources, shipyard queue,
            defence queue), reads the target's resources/fleet/defences and writes one report.
CONNECTED   the write path is the fleet worker (`process_fleet_movements`); `espionage_reports` is
            `deny_direct_api_access` and the ONLY reader is the owner contract `get_player_espionage_reports`
            (§5, extended in §10 with the reveal outcome; consumed by `EspionageReportsPanel`).
SAFE        the row is guarded by mission type + status and is keyed by fleet_id
            (`espionage_reports_fleet_id_key` ON CONFLICT → created_at refresh), so a replay cannot duplicate
            the report; ownership is `fleet_movements.player_id`, never a client parameter.
MISSING     buildings/research are NOT part of the report payload at all (see §10: OGameX thresholds 5/3 and 7/4
            have no LGI field to gate — extending the intel scope is a product decision, not a technical gap).
DEPENDS     nothing open on the critical path; see §7 (updated) and §10 for the residual list.
```

## 2. Authority and contract

| Object | Role |
|---|---|
| `resolve_espionage_arrival(fleet_id)` | the only write path (SECURITY DEFINER, internal: `postgres`/`service_role`) |
| `espionage_reports` | one row per espionage fleet: `espionage_level`, `target_espionage_level`, metal/crystal/deuterium/energy, `fleet` jsonb, `defenses` jsonb |
| espionage formula helper | **does not exist** — no detection helper is implemented today |
| client read contract | **does not exist** — the table refuses direct API access |

```text
resolve_espionage_arrival: requires mission_type = 'ESPIONAGE' and status = 'ARRIVED'
  · locks the fleet and the target planet
  · settles the target to the fleet's arrives_at (resources + shipyard/defence queues)
  · reads espionage_technology of attacker and defender (0 when the target has no owner)
  · INSERT ... ON CONFLICT (fleet_id) DO UPDATE SET created_at = clock_timestamp()
  · sets status = 'RETURNING' with returns_at = arrives_at + (arrives_at - started_at)
```

## 3. What the report actually contains today (2026-09-27, after §11)

```text
metal/crystal/deuterium      full target resources (never gated, OGameX parity)
energy                       the target's summed ship attack as stored in the report's `energy` field
fleet / defenses             jsonb maps, written ONLY when the OGameX reveal rule grants the section
buildings / research         jsonb maps (machine-name -> level), written ONLY when the rule grants them:
                             buildings from the target BODY, research from the target OWNER (§11)
ships_revealed / defenses_revealed / buildings_revealed / research_revealed
                             the four reveal decisions, stored at arrival (a true snapshot)
espionage_level / target_espionage_level
                             stored at arrival; the resolver consumes them for the gating and the chance
```

## 4. OGameX comparison (`7c420bad3478d7099791e1f33c920e9ff92822e8`)

`app/Services/CounterEspionageService.php` was read verbatim (3 091 bytes). The formula is unambiguous:

```text
chance% = floor(clamp(0, 100,
              defender_ship_count × (defender_espionage_level − attacker_espionage_level + 1)
              / (attacker_probe_count × 4) × 100 ))
trigger = random roll in 1..100 <= chance%          (0 → never, 100 → always)
defender_ship_count = ships only (defence structures are excluded from the battle)
```

```text
LGI actual   no counter-espionage at all: every espionage arrives, is reported in full and all probes return.
OGameX       chance formula above + EspionageMission resolves a BATTLE between the attacker's probes and the
             defender's ships when the roll triggers (probes are destroyed by combat resolution).
Difference   MISSING, and NOT a pure formula gap: LGI would have to run the combat engine with the probe fleet
             as attacker and the target's ships as defender, then remove the lost probes from
             fleet_movement_ships. That drags in two undecided points:
               (a) debris: do probes destroyed by counter-espionage create a debris field? OGameX was not read
                   for this, and LGI's combat path creates debris unconditionally;
               (b) whether the defender is notified (no messaging mechanic exists — see the sweep report).
Classification  PRODUCT DECISION (the chance formula is determined; the battle/debris policy is not).
             Deliberately NOT implemented: implementing only the dice roll would change nothing observable,
             and implementing the battle without the debris decision would silently move combat economics.
             The recorded formula is complete enough to implement in one step once the decision is taken.
```

## 5. Client read contract (2026-09-26)

Until this block the report data was unreachable: `espionage_reports` refuses direct API access
(`deny_direct_api_access`) and no function returned its rows. Migration
`20260926140000_add_owner_read_contracts_espionage_and_messages` added:

```text
get_player_espionage_reports(p_limit integer default 50)
  · SECURITY DEFINER, EXECUTE: authenticated / service_role (never anon)
  · rows are selected strictly through auth.uid() → players.user_id → players.id:
    a report belongs to the ATTACKER (er.player_id), so the caller can only ever read its own reports
  · returns report id, owning player, fleet id, target planet id + name + coordinates (galaxy/system/position),
    both espionage levels, metal/crystal/deuterium/energy, fleet jsonb, defenses jsonb, created_at
  · p_limit clamped to 1..200
```

```text
DEFENDER SIDE   still nothing. The report is the attacker's document; there is no defender-visible surface
                (no detection flag, no notification) — see §6/§7.
LEVEL GATING    APPLIED AT WRITE TIME since §9: `resolve_espionage_arrival` stores `{}` for a category the OGameX
                reveal rule denies (ships: 2 probes or level − 1; defence: 3 probes or level − 2). The contract
                returns that stored snapshot; since §10 it also returns the OUTCOME
                (`out_ships_revealed` / `out_defenses_revealed`) so the client can tell «not revealed» from «empty»
                without re-implementing the rule.
```

Tests: `supabase/tests/owner_read_contracts.sql` — **12 PASS + 1 INFO, LIVE 2026-09-26** (ownership isolation with
a foreign report present, payload/coordinate integrity, limit clamp, unauthenticated returns nothing, ACL).
Re-certified in §10 by `espionage_report_gating.sql` (17 PASS) and `espionage_read_contract_reveal_flags.sql`
(7 PASS).

## 6. Tests

```text
supabase/tests/owner_read_contracts.sql (1-3)   espionage: ownership isolation, payload + coordinates, limit clamp
No fixture exists for counter-espionage (nothing implemented to assert). This block changed no espionage write
function, so no espionage write fixture was re-run.
```

## 7. GAPS (status after §9 and §10)

```text
CLOSED 2026-09-26  messages + defender notification (messaging engine producers, §9).
CLOSED 2026-09-26  level gating of the report contents (OGameX reveal rule, §9; re-certified 2026-09-27, §10).
CLOSED 2026-09-26  probe loss and detection (counter-espionage battle + «fleet lost contact» + «you were espied»).
CLOSED 2026-09-26  retention: `purge_old_espionage_reports` is driven by `run_message_retention_worker()`, scheduled
                   by pg_cron `lagranimplosion-message-retention` daily at 04:00 (verified LIVE 2026-09-27).
CLOSED 2026-09-27  the report's intel had NO client consumer: `EspionageReportsPanel` showed only resources and the
                   probe counters. It now renders the reveal-gated ships/defence maps with their definitions' names,
                   the level pair, the energy column, the counter-espionage outcome and the reveal flags (§10).
CLOSED 2026-09-27  cross-owner read oracles that leaked buildings/research without an espionage mission (§10).
CLOSED 2026-09-27  the arrival resolver could not run inside a session carrying a JWT (engine-settle regression, §10).
CLOSED 2026-09-27  buildings and research ARE part of the report payload, gated server-side with the OGameX
                   thresholds 5/3 and 7/4 (§11). The previous entry classified this as a product decision and the
                   owner authorised it in this mission, so it is implemented, not invented.
OPEN (known)       counter-espionage does not count ships belonging to a foreign fleet holding at the target (OGameX
                   documents the same limitation with a TODO; ACS_HOLD combat is not implemented in LGI either).
```

## 9. COUNTER-ESPIONAGE — IMPLEMENTED (2026-09-26)

The product decision recorded in §8 is closed: counter-espionage is ADOPTED.

```text
Migrations  LIVE 2026-09-26
  20260926124000_counter_espionage_contract            espionage_reports.counter_espionage_chance,
                                                       .counter_espionage_triggered, .probes_sent, .probes_lost;
                                                       fleet_event_random; calculate_counter_espionage_chance;
                                                       get_planet_defender_ship_count
  20260926124010_espionage_arrival_counter_espionage   the rewritten resolver (chance + battle + gating + messages)
  20260926124030 / ...4035_fix_espionage_resolver_*    row-alias fixes: `fleet_id` and `status` are also OUT
                                                       parameters, so the guarded statements need aliases
  20260926124020_espionage_report_read_contract_...    the read contract now exposes the new fields

Formula (verbatim OGameX `CounterEspionageService::calculateChance`)
  chance% = floor(clamp(0..100, defender_ships × (defender_espionage − attacker_espionage + 1)
                                     / (attacker_probes × 4) × 100)); 0 when probes = 0, defender ships = 0 or
  the technology factor is <= 0. DEFENCE STRUCTURES NEVER COUNT.

Battle  the probe fleet (plus anything else it carried) fights the target's SHIPS through the EXISTING combat
        engine: a battle row exactly like the certified expedition battle (combat_battles + ATTACKER/FLEET +
        DEFENDER/PLANET + individual units at round 1) executed by the generic 6-round runner
        `run_expedition_combat` (verified battle-scoped, not expedition-specific) and settled with
        `create_combat_debris`. No second combat mechanic exists.

Consequences of a triggered battle
  · probe losses are written back to `fleet_movement_ships`, defender ship losses to `planet_ships`;
  · destroyed probes/ships DO create debris — at the TARGET planet, exactly like OGameX appends the battle debris
    to the target's field (LIVE fixture: 3 probes → 900 crystal at the target + a provenance row);
  · the defender IS notified: "You were espied" plus the battle report (the messaging engine's participant
    trigger). The attacker gets the espionage report, and "Fleet lost contact" when every probe died;
  · the espionage report is written EVEN IF every probe died; the return leg only exists when something survived,
    otherwise the movement goes straight to COMPLETED (no ghost return).

Reveal gating (implemented, closes §7)
  remaining = max(0, probes − max(0, defender_espionage − attacker_espionage)^2)
  ships    reveal when remaining >= 2  or attacker − 1 >= defender
  defence  reveal when remaining >= 3  or attacker − 2 >= defender
  (the OGameX thresholds for buildings 5/3 and research 7/4 have no LGI field to gate — LGI reports carry ships
  and defence only. Documented, not invented.)

REPLAY SAFETY  OGameX rolls with `random_int(1, 100)`; LGI must be replay-safe, so the roll is
               `floor(fleet_event_random(fleet, 'counter_espionage') × 100) + 1`, a pure function of the fleet's
               immutable dispatch timestamps. Re-running the resolver reproduces the same decision.
```

Tests: `supabase/tests/counter_espionage.sql` — **13 PASS + 1 INFO, LIVE 2026-09-26, ROLLBACK** (chance formula
table, report fields, reveal gating in both directions, real battle + PLANET participant + no defence unit, probe
loss, COMPLETED transition, defender ships untouched, debris + provenance, 4 messages, replay refusal with no
duplicate report, ACL).

Remaining gaps after this block:

```text
* Purge of `espionage_reports` (one row per flight, kept forever) — OUT OF SCOPE.
* Counter-espionage chance does not yet count ships belonging to a foreign fleet holding at the target
  (OGameX documents the same limitation with a TODO; ACS_HOLD combat is not implemented in LGI either).
* `fleet_event_random` is deterministic by design: it is a fidelity/anti-cheat choice, not an OGameX match.
```


```text
* Counter-espionage adoption: whether probes destroyed in a triggered counter-espionage battle produce debris,
  and whether the defender is notified. The chance formula itself is already determined (OGameX, §4).
* Whether report contents should be level-gated (espionage vs counter-espionage technology difference).
```


## 10. EVIDENCE SWEEP 2026-09-27 — gating re-certified, reveal outcome exposed, oracle leaks closed, settle regression fixed

Audit of the whole track (start → dispatch → travel → arrival → counter-espionage → report → persistence →
retrieval → UI → ACL) against the REAL code and LIVE, then implementation of every gap that was technical.

```text
WHAT WAS MEASURED FIRST (no assumption from older percentages)
  · `resolve_espionage_arrival` is the only writer; `espionage_reports` is `deny_direct_api_access` with the single
    policy `deny_direct_api_access` (qual = false) over its row-level SELECT grant; the only reader is the owner
    contract. A direct read returns 0 rows.
  · the frontend inventory (41 `supabase.rpc('…')` names) was diffed against LIVE: every name exists and is
    `authenticated`-executable → no broken wire.
  · no SECURITY DEFINER function in `public` lacks a pinned `search_path`; `anon` reaches only the 3 allow-listed
    names (`can_start_building`, `get_universe_evolution_monitor_public`, `sync_current_planet_resources`).
  · `supabase/tests/counter_espionage.sql` was NOT runnable: a stray statement after `ROLLBACK`
    (`v_fail := v_fail + …`) made the file fail as a script. REMOVED; the fixture is executable again.
```

### 10.1 Level gating (buildings / research) — VERIFIED, nothing to change

* The report payload is `fleet` + `defenses` ONLY: there is no building or research section anywhere in the
  contract, so the OGameX thresholds 5/3 (buildings) and 7/4 (research) have no LGI field to gate. Extending the
  intel scope would be a NEW player capability → product decision, not implemented (see §7).
* For the two sections that DO exist the gate is applied server-side by the resolver, and the full ladder was
  REPLAYED LIVE: `espionage_report_gating.sql` → **17 PASS** (levels 0→4 against a level-0 defender, the probe budget
  against a gap of 2 — 1 probe hides everything, 6 probes reveal ships, 8 probes reveal ships+defence —, the mixed
  frontier 3 vs 2, the moon target, resources never gated, the energy column, snapshot semantics, ACLs, and that
  neither `authenticated` nor `anon` can read the table directly).
* `counter_espionage.sql` → **13 PASS** (chance formula table, report fields, real battle + PLANET participant with
  no defence unit, probe loss, COMPLETED transition, defender ships untouched, debris + provenance, 4 messages,
  replay refusal without duplication, ACL).

### 10.2 GAP — the certified intel had no consumer (backend closed, UI missing)

```text
FINDING     `EspionageReportsPanel` rendered only coordinates, resources and the probe counters. The reveal-gated
            `fleet` / `defenses` maps — the whole point of the gating — were never shown, and because a denied
            category is stored as `{}`, the client could not tell «not revealed (level gap)» from «nothing there»
            without re-deriving the OGameX rule (forbidden: the frontend is never a second source of truth).
IMPLEMENTED 20260927120100_espionage_report_reveal_flags — `get_player_espionage_reports` also returns
            `out_ships_revealed` / `out_defenses_revealed`, DERIVED SERVER-SIDE from the stored snapshot
            (`espionage_level`, `target_espionage_level`, `probes_sent`) with the very expression the resolver used,
            so it can never drift and it keeps the snapshot semantics (a later technology level does not upgrade an
            old report). Ownership, ACL, the 1..200 clamp and the column order are unchanged (columns appended).
UI          `EspionageReportsPanel` now shows both maps with the unit names from the certified
            `ui_ship_definitions` / `ui_defense_definitions` contracts (an unknown id is printed as-is, never
            invented), the level pair, the energy column, the counter-espionage outcome and the revealed/not-revealed
            state. The message centre's ESPIONAJE row also reports the counter-espionage outcome and the reveal
            state. No client-side gating logic was added.
CERTIFIED   supabase/tests/espionage_read_contract_reveal_flags.sql — **7 PASS + 1 INFO, LIVE, ROLLBACK**: the
            denied case (0 vs 2, 1 probe), the level gap eating the extra probe (1 vs 2, 2 probes → remaining 1),
            ships-only (0 vs 1, 3 probes → remaining 2), both categories (1 vs 1, 5 probes), the snapshot semantics

### 10.3 GAP — cross-owner read oracles on BUILDINGS and RESEARCH

```text
FINDING (reproduced as `authenticated`, LIVE)  five client-callable SECURITY DEFINER contracts took the target of
            the read from a CLIENT PARAMETER with no ownership gate, so any signed-in player could read another
            empire's buildings/research without ever sending a probe:
              get_research_network_lab_level(p_player_id, p_planet_id, p_research_id) → the research_lab level of
                ANY planet + the intergalactic_research_network level of ANY player (and the empire's best N labs);
              calculate_research_time(...) → the same leak through the returned duration;
              calculate_max_colony_slots / check_colony_cap(p_player_id) → astrophysics level, colony cap, planets;
              calculate_player_category_scores(p_player_id) → recomputes a whole foreign empire's score buckets
                (also a compute amplifier: generate_series × calculate_building_cost per level).
            Nothing in LGI makes a foreign planet's building/research level public (the espionage report does not
            carry them), and the only public score surface is `get_universe_ranking_by_category`.
IMPLEMENTED 20260927120000_harden_cross_owner_research_and_colony_reads — the certified identity gate used by
            `inspect_demolition` / `calculate_planet_storage` (`auth.uid() IS NOT NULL AND not owner`) plus, for the
            planet-scoped helpers, the planet-belongs-to-that-player check, so passing one's OWN player id with a
            FOREIGN planet id is refused too. `check_colony_cap` answers with a blocked ROW
            (`allowed=false`, `PLAYER_NOT_OWNED_BY_AUTH_USER`, numbers NULL) like `can_start_building` does.
            `auth.uid() IS NULL` (engine workers, AI service actor — verified `authenticated = false` for
            process_fleet_movements / resolve_colonize_arrival / recalculate_* / run_ranking_worker) is unchanged.
CERTIFIED   supabase/tests/cross_owner_research_and_colony_reads.sql — **6 PASS + 1 INFO, LIVE, ROLLBACK**:
            foreign id refused on all five, own-player + foreign planet refused, the owner path intact, the
            no-JWT worker path intact, ACL/SECURITY DEFINER/`search_path` unchanged, no PUBLIC grant left.
```

### 10.4 REGRESSION — the engine settle path depended on the caller's JWT (found by re-running the certification)

```text
SYMPTOM (reproduced LIVE)  as the certification actor (`request.jwt.claims` set):
            resolve_espionage_arrival(<foreign target>) → ERROR P0001: PLAYER_NOT_OWNED
            CONTEXT: calculate_planet_storage(uuid) line 18 → update_planet_resources_until_raw line 64 →
                     update_planet_resources_until line 24 → resolve_espionage_arrival line 42.
CAUSE      `20260926280000` added the ownership gate to the CLIENT contract `calculate_planet_storage` and assumed
           the gate only had to be skipped when `auth.uid() IS NULL` ("exactly the service/worker context"). But an
           engine settle running inside a session that CARRIES a JWT settles the TARGET planet (owned by the other
           player), so the client gate aborted the whole espionage resolution — arrivals, returns, completions.
           The gating fixture papered over it (`set_config('request.jwt.claims','',true)` around the resolver);
           `counter_espionage.sql` did not, which is why it could no longer run at all.
WHY IT IS A DEFECT  a closed, certified system (espionage) regressed, its certification was not reproducible, and an
           engine-internal settle had become a function of the ambient authentication state (a landmine for any
           future tick triggered from an authenticated session).
FIX        20260927120200_fix_engine_settle_storage_regression — the repository's own internal/client split
           (`can_start_building` + `evaluate_building_start_internal`):
             · `calculate_planet_storage_internal(planet)` — the computation verbatim WITHOUT the gate, DEFINER,
               pinned search_path, `service_role` only;
             · `calculate_planet_storage(planet)` — the UNCHANGED client contract: the certified gate (still raising
               PLAYER_NOT_OWNED, still `pl.user_id = auth.uid()`) and then delegation to the internal helper;
             · the engine-only consumers (`update_planet_resources`, `update_planet_resources_until_raw`,
               `execute_expedition_merchant_trade`; all `authenticated = false`) were repointed with a guarded
               catalogue substitution that asserts the anchor, is idempotent and refuses to drift.
           Postconditions inside the migration: ACLs unchanged, the gate still present verbatim, the internal helper
           gate-free, and NUMERIC EQUIVALENCE `calculate_planet_storage(p) = calculate_planet_storage_internal(p)`
           for EVERY planet with resources. The economy (formulas, multiplier, item bonus, rounding) is untouched.
VERIFIED   the resolver now settles a foreign planet with a JWT present (status RETURNING, 1 report) and
           `counter_espionage.sql` passes again — 13 PASS.
```

### 10.5 Residual (measured, not assumed)

```text
TECHNICAL          none known on this track: every path above was re-run after the fixes.
PRODUCT DECISION   buildings/research intel in the espionage report — CLOSED in §11 (the owner authorised it; the
                   OGameX thresholds 5/3 and 7/4 are now implemented server-side).
KNOWN LIMITATION   a foreign ACS_HOLD fleet at the target is not counted by the counter-espionage chance (OGameX TODO).
```


## 11. BUILDINGS + RESEARCH IN THE REPORT — IMPLEMENTED (2026-09-27)

The product decision recorded in §7/§10.1 is CLOSED by owner authorisation: the espionage report now carries the two
remaining OGameX categories, gated server-side at arrival.

```text
MIGRATION  20260927130000_espionage_report_buildings_and_research
  columns    espionage_reports.buildings jsonb NOT NULL DEFAULT '{}'   (machine-name -> level)
             espionage_reports.research  jsonb NOT NULL DEFAULT '{}'
             espionage_reports.ships_revealed / defenses_revealed / buildings_revealed / research_revealed boolean
  resolver   resolve_espionage_arrival writes the two new sections and the four flags in the same INSERT:
               v_reveal_buildings := v_remaining >= 5 or (v_esp - 3) >= v_target_esp;
               v_reveal_research  := v_remaining >= 7 or (v_esp - 4) >= v_target_esp;
             buildings = jsonb_object_agg(building_id, level) over planet_buildings of the TARGET BODY;
             research  = jsonb_object_agg(research_id, level) over player_research of the TARGET OWNER
                         (skipped when the target body has no owner).
             Both are stored as '{}' when the rule denies the section, so a denied section stores NOTHING.
  contract   get_player_espionage_reports also returns out_buildings, out_research, out_buildings_revealed and
             out_research_revealed (same ownership chain, same 1..200 clamp, same ACL: authenticated/service_role,
             never anon). The two older flags are now read from the stored snapshot too; the migration backfilled
             them with the exact expression `20260927120100` used to derive them at read time and asserts that EVERY
             pre-existing row keeps the answer it already had (0 drift, verified in the migration itself).
  compatibility  columns appended, the API answer only grows, existing reports keep working; rows created before
             this migration carry buildings/research = '{}' and both new flags FALSE (they have no such payload, so
             «not revealed» is the honest answer).
```

OGameX reference (read verbatim at `7c420bad3478d7099791e1f33c920e9ff92822e8`): `app/GameMissions/EspionageMission.php`
evaluates `canRevealData($remainingProbes, $attacker, $defender, 5, 3)` for `$report->buildings =
$targetPlanet->getBuildingArray()` and `(…, 7, 4)` for `$report->research = $targetPlayer->getResearchArray()`, with
`remainingProbes = max(0, probes − pow(max(0, defender − attacker), 2))` and
`canRevealData = remainingProbes >= probeThreshold || attackerLevel - levelThreshold >= defenderLevel`;
`app/Models/EspionageReport.php` casts `buildings`/`research` as `array<string, int>` (machine-name -> level) and keeps
no boolean flags (an absent section is simply not written).

Deliberate LGI adaptations (concept, not a copy):
1. the outcome is materialised as four stored booleans so the browser can distinguish «not revealed» from «empty»
   without re-implementing the rule (the frontend is never a second source of truth);
2. LGI does not zero-fill absent buildings/research: the maps carry what the target actually has, which is LGI's own
   state representation and the same shape as the certified `fleet`/`defenses` maps (payload-shape detail, no
   gameplay effect);
3. the write stays in the single existing resolver statement, so the section is a snapshot taken at arrival.

UI: `EspionageReportsPanel` renders both new sections with the names from the certified `ui_building_definitions` /
`ui_research_definitions` contracts (an unknown id prints as-is), or «no revelados (nivel de espionaje insuficiente)»
when the flag is false. The message-centre ESPIONAJE row reports the four reveal states as well.

CERTIFIED (LIVE, transactional `ROLLBACK`, zero residue)
```text
supabase/tests/espionage_read_contract_reveal_flags.sql   13 PASS + 1 INFO
  A/B denied cases, C ships-only, D 5 probes -> ships+defence+buildings (the buildings threshold),
  E snapshot semantics for all four sections, G a table-driven block over six level/probe configurations where the
  fixture DERIVES the expected outcome from the OGameX rule itself and also asserts that a denied section stored
  nothing and a revealed one stored the target's real data, F1/F2 ownership + table closure + clamp.
supabase/tests/espionage_report_gating.sql                17 PASS + 1 INFO
  replayed after this migration: the level ladder, the probe budget, the moon target, resources never gated,
  snapshot semantics and the client-bypass assertions all still hold (no regression).
```

Residual: buildings/research are NOT part of the ranking or any other contract (unchanged); the counter-espionage
chance still does not count a foreign holding fleet (OGameX parity, §7).



## 12. CURRENT VERIFIED BASELINE — 2026-09-27

This section supersedes stale historical wording in §1, §5, §7 and the residual notes in §9.

- Buildings and research are **implemented and LIVE**, not a pending product decision.
- The authoritative reveal thresholds are 5/3 for buildings and 7/4 for research, applied by
  `resolve_espionage_arrival` using the same remaining-probe calculation as the other report sections.
- `get_player_espionage_reports` returns the four maps and four stored reveal flags through the owner-scoped
  authenticated contract.
- The implementation migration is LIVE:
  `20260927130000_espionage_report_buildings_and_research`.
- The related LIVE certification reported by the migration/fixtures covers both positive and negative gating,
  snapshot semantics, ownership isolation and direct-table closure.
- The UI consumer is already wired through `EspionageReportsPanel`; it consumes the server-returned flags and
  definition contracts rather than reproducing the gating formula.

### Current residual

The remaining known limitation on this track is the documented OGameX parity limitation around foreign fleets holding
at the target during counter-espionage. This is coupled to the existing ACS_HOLD model and is not part of the
buildings/research gating work.

Historical sections above remain useful as an audit trail; when they say buildings/research are "MISSING" or a
"PRODUCT DECISION", read those statements as the state **before §11**.
