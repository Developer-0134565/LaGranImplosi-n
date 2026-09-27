# ACTIVE AI — LA GRAN IMPLOSIÓN

> The execution contract that lets an AI player act through the SAME authoritative mechanics as a human, without
> weakening a single ownership gate, plus the owner-approved behaviour policy that decides what an AI does and when
> (§7). No rule of the game is duplicated by the AI: it asks the certified contracts.
> Related: [`README_IDENTITY_AND_ACCESS.md`](README_IDENTITY_AND_ACCESS.md) (ownership chain),
> [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md), [`README_ECONOMY.md`](README_ECONOMY.md),
> [`README_RESEARCH_ENGINE.md`](README_RESEARCH_ENGINE.md), [`README_ESPIONAGE_ENGINE.md`](README_ESPIONAGE_ENGINE.md),
> [`../reference/README_OGAMEX_LGI_MAP.md`](../reference/README_OGAMEX_LGI_MAP.md).
> Operational status: [`../PROJECT_CONTEXT_PROMPT.md`](../PROJECT_CONTEXT_PROMPT.md).

## 1. Problem and accepted model (2026-09-26)

```text
Problem   every authoritative dispatcher derives its actor from `auth.uid()` (`start_building`, `start_research`,
          `start_ship`, `start_defense`, `start_fleet`, `start_fleet_mixed`, `start_support_fleet`,
          `start_colonize_fleet`), and the ownership trigger `enforce_player_write_access` refuses every session-less
          write. An AI player (`player_type = 'AI'`, `user_id IS NULL`) could therefore never act, while the old
          guest branch that used to allow it is dead and must NOT be reopened.
Accepted  service actor → validate AI player ownership/state → invoke the authoritative mechanic
Rejected  disabling or weakening an ownership gate, or executing as an arbitrary player
```

## 2. Contract

| Object | Role | ACL |
|---|---|---|
| `ai_actor_begin(ai_player_id)` | declares the AI execution context for the current transaction: requires a service context (no session, non-client role) plus an AI player of an ACTIVE universe with no session owner; stores `lgi.ai_worker='on'` and `lgi.ai_player=<id>`, transaction-local | `service_role` only |
| `is_ai_actor_target(player_id)` | the ONLY question the gates ask: no session **and** non-client role **and** a context declared **for this very player** **and** the player is an AI player without a session owner | `service_role` only |
| `ai_actor_end()` | clears the declaration | `service_role` only |
| `enforce_player_write_access` | accepts the declared AI actor for AI players; everything else keeps raising `AUTHENTICATION_REQUIRED` / `PLAYER_NOT_OWNED_BY_AUTH_USER` | trigger |

Integration is minimal and asserted: each gate gained
`v_auth_user IS NULL AND NOT public.is_ai_actor_target(p_player_id)`, or
`(coalesce(pl.is_guest,false) or public.is_ai_actor_target(pl.id))` in the fleet dispatchers. No gate was removed, no
function became public, and no dispatcher was rewritten.

```text
Execution actor   the service worker (cron / service role) — it must declare itself
Action owner      the AI player — validated server-side (type, universe, no session owner)
Isolation         the declaration is transaction-local and player-bound: it cannot leak between requests and cannot
                  be used for a different player (fixture assertion 4)
```

## 3. Tests

```text
supabase/tests/ai_service_actor.sql — 9 PASS + 1 INFO (LIVE 2026-09-26, rolled back, zero residue)
  1. an undeclared session-less call for an AI player is refused (Authentication required)
  2. a human player cannot be declared as an AI actor (AI_ACTOR_TARGET_NOT_AI)
  3. the declared AI actor really built through `start_building` (queue row created, metal charged)
  4. the declaration is bound to one player: acting for another AI player is refused
  5. the write-access trigger accepts the declared actor for `fleet_movements`
  6. after `ai_actor_end` the same write is refused again (AUTHENTICATION_REQUIRED)
  7. an authenticated human cannot act for an AI player
  8. a human session keeps its normal authority (no regression)
  9. ACL: the three contract functions are service-role only

supabase/tests/ai_behaviour_policy.sql — 20 PASS (LIVE 2026-09-26, rolled back, zero residue) — §7 behaviour
  1a/1b deterministic daily schedule (same player+date reproduces it; other dates differ) · 2 3–6 h in 2–5
  windows over 60 generated days · 3 windows ordered and disjoint, ai_is_active_at true inside / false in the gap
  · 4a/4b personality assigned once and never re-rolled, humans refused · 5 planet template + variation persist
  and follow the personality · 6 cooldown ranges per family and monotonicity in the roll · 7a/7b the human
  neighbour IS a legal, known, weak attack candidate and a 1-hour-old AI still does not attack it (no ATTACK
  movement) · 8 espionage dispatched through `start_fleet_mixed` · 9 the power estimate equals the certified
  `get_combat_*` sum and the unknown owner adds exactly the documented 1.15 · 10a/10b attack-probability zones
  and a real probabilistic attack with a favourable deterministic roll · 11 colonisation · 12 colonisation FROM A
  MOON · 13 fleet slots respected (no fleet family with 0 free slots) · 14 colony cap respected · 15 an inactive
  window executes nothing · 16 the worker stays inside the declared actor and clears it.

supabase/tests/ai_player_policy.sql — 6 PASS + 1 INFO (policy-independent contract surface: budget validation,
  budget invariant, the declared actor refuses humans, worker batch without errors, ACL of the functions and the
  profile tables, cron tick). Its original priority-list assertions were superseded when 20260926291000 replaced
  the first-cut policy; the behaviour coverage lives in ai_behaviour_policy.sql.

LIMITATION  single-session harness; the cron tick is asserted statically and no two workers run concurrently.
```

## 4. Behaviour policy — IMPLEMENTED (2026-09-26, owner-approved)

The contract is deliberately behaviour-free: it defines **how** an AI may act, not **what** it should do. The
policy that decides what an AI does is implemented in `20260926290000/…291000` and documented in **§7**; it is
LGI's own policy because OGameX has none to port (§5). What this section used to list as open questions is now
answered in §7 (action choice, cadence, budget and reserve, colonisation, attack policy and the protection
window), and every answer is executed through the certified contracts — never by a second rule engine.

## 5. OGameX comparison (`7c420bad3478d7099791e1f33c920e9ff92822e8`)

```text
FOUND      `NPCPlanetService`, `NPCPlayerService`, `NPCFleetGeneratorService`,
           `Console/Commands/Admin/InitializeLegorAccount`, `Jobs/CreateLegorMoon` run NPC work from the Laravel
           console/queue context, i.e. outside the web session — the same separation of actor and account that this
           contract implements.
ADAPTED    Laravel has no equivalent of the Supabase `auth.uid()` ownership chain, so LGI needs an explicit,
           declarable actor plus a per-player binding: `ai_actor_begin` + `is_ai_actor_target`.
NOT COPIED the NPC behaviour policies themselves (priority lists, budgets, thresholds) are Laravel service code
           tuned to OGameX's settings; transcribing them would be inventing a policy here. The behaviour policy
           of §7 is LGI's own, owner-approved, and is declared as such.
READ (2)   `GameMissions/ColonisationMission.php`: the validity list is target-side only (target must be a
           PLANET, must be empty, position inside MIN..MAX_PLANET_POSITION, astrophysics must allow the position,
           at least one colony_ship). OGameX imposes NO origin-kind restriction at mission level, which matches
           LGI: a colony may be launched from a moon, and §7 assertion 12 certifies the AI using that route.
READ (3)   `GameMissions/EspionageMission.php`: planets and moons are probeable, probes are required, destroyed
           moons are not; the payload is level-gated by `canRevealData(remainingProbes, attackerLevel,
           defenderLevel, probeThreshold, levelThreshold)` with (2,1) ships, (3,2) defences, (5,3) buildings,
           (7,4) research. LGI implements the ships/defences gates (README_ESPIONAGE_ENGINE) and its reports carry
           no buildings or research, so the AI only ever uses ships, defences and resources — exactly what §7 uses.
INCOMPAT.  none.
Status     FOUND (separation of actor vs. owner, mission validity lists) · ADAPTED (the contract) ·
           IMPLEMENTED (behaviour policy §7, LGI's own)

## 6. Housekeeping

```text
* `reconcile_universe_ai_population` still creates AI planets with the service context and is NOT part of this
  contract (it does not need an actor: it writes new AI players, it does not act as them). Personalities are
  assigned lazily on first use by `ai_ensure_player_profile`, so population reconciliation needed no change.
* An AI worker wraps every batch in one transaction: `ai_actor_begin(ai_id)` … `ai_actor_end()`, so the
  declaration can never outlive the batch.
* If a future action needs a contract that does not exist yet, it must be created as a service-role function that
  validates the AI target — never by relaxing a client-facing gate.
* The AI never calls `random()`: every roll is `ai_roll(player, kind, tick)` (a hash), so replaying a tick
  reproduces exactly the same decision. This is what makes the policy testable and auditable.
* Invariant relied on by the policy: every body has a `planet_resources` row (verified 585/585 on 2026-09-26).
  A body without one is a data anomaly, not a policy case.
```

## 7. Behaviour policy (2026-09-26) — what an AI does, and when

Migrations: `20260926290000_ai_behaviour_model.sql` (state + deterministic helpers),
`20260926291000_ai_behaviour_policy.sql` (the policy and the worker). Two forward-only corrections came out of
LIVE testing: `20260926292000` (OUT-parameter/column ambiguity in `ai_ensure_player_profile`) and `20260926293000`
(the unknown-owner hull convention of `ai_composition_power`, which had overestimated every defender by 10× on the
hull component). `20260926220000` had given the actor a first-cut policy (energy → lowest mine → research list →
colony); `20260926291000` replaced it, the behaviour assertions moved to the new fixture, and
`ai_player_policy.sql` now certifies only the policy-independent contract surface.

```text
Owner-approved principles (the AI plays like a human, badly)
  * the AI obeys exactly the same rules: it cannot skip a contract, create resources, see information it does not
    have, or act without requirements (LIVE proof: an AI without shipyard 3 + espionage_technology 2 is refused
    by start_fleet_mixed with SHIP_REQUIREMENT_FAILED);
  * randomness may only choose among LEGAL actions (the legality check always runs first);
  * the AI is not a worker: 3–6 h of activity per day, cooldowns, and whole windows with no decisions at all;
  * no attack during the AI's first 24 h — no exception, not even against a human neighbour.
```

### 7.1 Personality (persistent, assigned once)

`ai_player_profiles(player_id, personality, budget_percent, last_action_at, last_action_kind, next_action_at)` —
`ai_ensure_player_profile(player)` assigns the personality on first use from `hash(player_id)` and never re-rolls
it (fixture 4a). Weights are decision weights, not resource shares (`ai_personality_weights`):

| personality | economy | research | military | espionage |
|---|---|---|---|---|
| INDUSTRIAL | 45 | 25 | 20 | 10 |
| SCIENTIST | 30 | 40 | 15 | 15 |
| MILITARY | 20 | 25 | 40 | 15 |
| PREDATOR | 20 | 20 | 35 | 25 |

### 7.2 Daily activity (deterministic, 3–6 h in 2–5 windows)

`ai_daily_activity(player, date)` derives everything from `hash(player_id + UTC_date)`, so a worker tick can never
re-roll a schedule:

```text
total := 180 + hash%181 minutes      -> 3 h .. 6 h (fixture 2: 60 generated days inside 3–6 h)
windows := 2 + hash%4                -> 2 .. 5 separate windows
first rest := 120 + hash%401 minutes -> the schedule is never aligned with UTC midnight
rest between windows := remaining minutes / windows (integer + remainder)
```

`ai_is_active_at(player, at)` answers the only question the policy asks. Outside the windows `ai_decide_and_act`
returns `(none, null, 'AI_INACTIVE_WINDOW')` and touches nothing (fixture 15). The pg_cron tick stays at 5
minutes: the schedule, not the job, decides when a decision may happen.

### 7.3 Planet specialisation

`ai_planet_profiles(planet_id, template, variation)` + `ai_planet_profile(planet)`, assigned lazily and
deterministically. The template is drawn from the personality's preference list (an INDUSTRIAL AI never gets a
FLEET_BASE, fixture 5) and `variation` ∈ [0,1) shifts strategic need slightly so two identical planets do not
develop identically. Templates: `MINING_WORLD`, `RESEARCH_WORLD`, `MILITARY_WORLD`, `FLEET_BASE`,
`EXPANSION_WORLD`; they bias the building choice (research lab / shipyard / mines) and the unit doctrine.

### 7.4 One decision per tick, scored

```text
score = personality weight × affordability × strategic need × random(0.80..1.20)
```

* `random` is `ai_roll(player, kind, tick)` — deterministic per (player, kind, UTC minute), never `random()`.
* affordability keeps the old explicit budget rule: at most 60 % of each stored resource (default
  `budget_percent`) and 1000 deuterium always reserved for fuel.
* the families are building, research, shipyard, defence, espionage, attack and colonisation; the highest score
  wins and is executed through the certified dispatcher. If nothing scores, `AI_IDLE`.
* the focus body rotates deterministically by UTC hour, so multi-planet AIs work everywhere.

### 7.5 Cooldowns

`ai_cooldown_minutes(kind, personality, roll)`: building 10–35, research 30–120, production (shipyard/defence)
20–90, fleet 20–90, espionage 15–60, attack 45–180, colonisation 120–360 minutes, scaled by personality
(MILITARY/PREDATOR 0.70 on fleet/attack/espionage; SCIENTIST 0.75 on research and 1.30 on fleet/attack;
INDUSTRIAL 0.80 on building/colonisation and 1.25 on attack; PREDATOR 1.15 on building/research). The profile
stores `next_action_at`, and the tick returns `AI_COOLDOWN_UNTIL_<time>` while it holds.

### 7.6 Espionage, targeting and combat power

* `ai_espionage_candidates(player, origin, limit)` ranks foreign bodies by the certified distance helper
  (`calculate_fleet_distance_to_coordinates`) with a deterministic per-candidate jitter, so the nearest body is
  not automatically chosen. Probes are required and the mission goes through `start_fleet_mixed(..., 'ESPIONAGE')`.
* `ai_known_target_power(player, target)` reads the AI's latest `espionage_reports` row. If the certified reveal
  gate did not include ships or defences the answer is `known = false` and the AI will not attack: it never
  guesses a strength it was not given. Fixture 10b uses a real report.
* `ai_composition_power(ships, defences, player_id)` reuses the certified
  `get_combat_{ship,defense}_{attack,shield,hull}` helpers for the AI's own strength; for a target (unknown
  research) it uses the definitions with the SAME hull/10 convention plus a documented 1.15 conservatism
  (fixture 9 asserts both).
* `ai_attack_candidates(player, origin, budget, limit)` computes the sendable power (the AI's warships × the
  budget share) and `relative_power = sendable / target_power`.

### 7.7 Attack policy and the 24 h protection

```text
zones (owner-approved):  <0.75 rarely (base 0.02) · 0.75–0.95 opportunistic (0.15)
                         0.95–1.25 favourable (0.35) · >1.25 very favourable (0.60)
personality multiplier:  PREDATOR 1.30 · MILITARY 1.10 · SCIENTIST 0.70 · INDUSTRIAL 0.50 (ceiling 0.85)
```

The zone is a probability, not a rule: the policy still rolls (`ai_roll(player, 'attack_roll|<target>', tick)`).
An AI younger than 24 h (`players.created_at`) never attacks anybody — the gate runs before the probability, so
the result is `AI_PROTECTION_24H` even when a legal, known, weak human target exists (fixtures 7a/7b). Humans are
ordinary candidates afterwards: there is no artificial preference for them, and no target-side beginner
protection is implemented (that would be a new product decision). Attacks commit a share of each warship type
present, never the whole fleet, and always obey the fleet-slot trigger.

### 7.8 Colonisation and fleet doctrine

* Colonisation requires `check_colony_cap` to allow it, a colony ship on the origin, a free coordinate found by
  scanning the AI's galaxy, fuel and a free fleet slot; its score is deliberately low against economy actions.
* Colonisation FROM A MOON works (OGameX has no origin-kind restriction and LGI accepts it) and fixture 12
  certifies the AI using that route; no backend change was needed.
* Ship/defence doctrine comes from `ai_unit_preference(kind, personality, template)` (INDUSTRIAL transports,
  SCIENTIST probes, MILITARY combat ships, PREDATOR offensive ships + probes) and `ai_pick_unit` picks the first
  entry the certified `can_build_ship`/`can_build_defense` allows and the budget can pay.

### 7.9 Anti-snowball limits (by construction)

3–6 h of activity per day, real inactivity windows, per-family cooldowns, probabilistic decisions, the 60 % budget
with a deuterium reserve, normal requirements, partial fleet commitment and limited expansion. The AI never
maximises every available minute, and it can idle for hours with resources in storage (fixture 13 shows a 0-slot
AI doing nothing rather than pushing).

### 7.10 ACL, scheduling and determinism

`ai_decide_and_act(player, budget default 60, at default now())` and
`run_ai_policy_worker(max_players default 25, budget default 60, at default now())` are **`service_role` only**;
both profile tables have RLS with `deny_direct_api_access` and no client grants. The `at` parameter exists so a
tick can be evaluated deterministically (the fixtures select instants inside and outside a window; the cron calls
the worker with the default). Scheduling: pg_cron `lagranimplosion-ai-policy` every 5 minutes (unchanged), and the
worker walks the population with a deterministic round-robin slice (`20260926294000`): one `p_max_players` slice
per tick, so all 586 AI players are visited within ~2 h instead of the same first 25 forever whenever nothing was
acted on.
Tests: `supabase/tests/ai_behaviour_policy.sql` **20/20 PASS LIVE** (see §3) and
`supabase/tests/ai_player_policy.sql` **6/6 PASS LIVE** for the policy-independent contract surface.

### 7.11 Divergences from OGameX (declared)

```text
OGameX has no player-AI policy at all: its NPC code generates enemy fleets for expedition battles. Therefore
  * every personality, cadence, cooldown, score, threshold and doctrine in §7 is LGI's own, declared as a product
    policy — none of it is presented as an OGameX rule;
  * conversely, nothing in §7 invents a GAME rule: mission validity, requirements, costs, fuel, fleet slots,
    colony caps, combat stats and report contents all come from the certified contracts;
  * OGameX sources were read only for the mission/espionage rules cited in §5, and LGI already matches them.
```

### 7.12 Declared limit observed LIVE (product decision, not implemented)

```text
Measured 2026-09-26 before the bootstrap fix:
  * the pg_cron worker was evaluating AI players (25 ai_player_profiles rows, all four personalities);
  * all 586 AI planets held 0 metal / 0 crystal / 0 deuterium and 0 building rows, because
    reconcile_universe_ai_population inserted planet_resources(..., 0, 0, 0, ...) at creation.

Consequence: with the certified 60 % budget rule an AI player could never afford a FIRST action, so production
ticks resolved to AI_IDLE.

RESOLVED for every NEW AI by 20260926296000 (§8): the AI seeder now uses the human bootstrap. The 586 existing AI
empires are deliberately left untouched (they keep 0 resources and stay DORMANT) and normalising them is an OPEN
product decision, reported and NOT performed.
```

## 8. Initial bootstrap parity + DORMANT state (2026-09-26)

Migrations: `20260926295000_ai_dormant_state.sql` (persistent status + policy gate + worker filter) and
`20260926296000_shared_player_bootstrap.sql` (one bootstrap authority for humans and AI).

### 8.1 One bootstrap authority (option B of the brief)

The two birth paths were measured LIVE before the change:

```text
provision_player (human)                        reconcile_universe_ai_population (AI)
--------------------------------------------    --------------------------------------------------
players: user_id = auth.uid(), last_activity    players: user_id NULL, username AI-Gx-Sy-Pz (rest identical)
planets: 'Homeworld', 163 fields, homeworld     planets: 'AI World …', 163 fields, homeworld, NULL temps
planet_resources: 500 / 500 / 0 / 0             planet_resources: 0 / 0 / 0 / 0      <-- DIVERGENCE
initialize_player_research -> 16 x level 0      (not called)                          <-- DIVERGENCE
buildings / ships / defences: none              none
```

`public.bootstrap_new_player_state(player_id, planet_id)` is now the single authority for the initial state:

* it inserts **only** the planet id into `planet_resources`, because the initial endowment lives in the schema
  defaults (`metal 500`, `crystal 500`, `deuterium 0`, `energy 0`, timestamps `now()`). There is therefore no
  quantity to copy anywhere — a human and an AI cannot drift apart, and the helper adds nothing on a second call
  (idempotent);
* it calls the existing, reusable `initialize_player_research(player)` (idempotent: one level-0 row per research
  definition, 16 today);
* `provision_player` (human) **delegates** to it, keeping its signature, ACL, `search_path`, returned columns and
  every other statement;
* `reconcile_universe_ai_population` (AI) **delegates** to it instead of writing literal zeros, and additionally
  calls `ai_ensure_player_profile` so the persistent DORMANT profile exists from birth.

No AI multiplier, bonus, penalty or extra quantity exists; nothing else was changed in either function.

### 8.2 DORMANT / ACTIVE (persistent, explicit)

```text
ai_player_profiles.status   text NOT NULL DEFAULT 'DORMANT' CHECK (status IN ('DORMANT','ACTIVE'))
```

DORMANT is a **persistent state**, never an inference: it is not derived from `last_action_at IS NULL`, empty
resources, empty buildings, a magic date or any other heuristic. A missing profile row counts as DORMANT too.

Enforcement is double:

1. **Policy gate** — `ai_decide_and_act` is now a gate that answers `(none, null, 'AI_DORMANT')` before any
   evaluation, so a DORMANT AI consumes no budget, reaches no certified dispatcher and does not even run the
   policy body. The certified body was preserved byte-for-byte by renaming it to `ai_decide_and_act_core` and
   revoking EXECUTE from every role, so the gate is the only reachable entry point.
2. **Worker** — `run_ai_policy_worker` walks ACTIVE players only, keeping the deterministic round-robin of
   `20260926294000` (it now rotates over the ACTIVE population; a fully dormant population costs nothing).

DORMANT affects the AI policy **only**: the economy engine is untouched, so an AI planet keeps receiving the same
production/queue/worker ticks a human would receive (those workers do not filter by `player_type`).

### 8.3 Activation seam (prepared, not implemented)

```text
activate    UPDATE public.ai_player_profiles SET status = 'ACTIVE' WHERE player_id = <uuid>;   (service_role)
put to sleep UPDATE public.ai_player_profiles SET status = 'DORMANT' WHERE player_id = <uuid>;  (service_role)
```

There is deliberately **no** client-facing RPC, no button and no automatic activation: the state is prepared for a
future product decision (deferred bootstrap of the existing AI population, activation policy, cadence).

### 8.4 Tests

```text
supabase/tests/ai_bootstrap_and_dormant.sql — 14 PASS + 1 INFO (LIVE 2026-09-26, rolled back, zero residue)
  1. the seeder-born AI has the exact initial state (500/500/0/0, 16 level-0 research rows, 0 buildings/ships/
     defences) — values compared, not "not null";
  2. a REAL human birth (provision_player, with a temporary rolled-back auth user) and a REAL AI birth
     (reconcile) produce identical player/planet/resource/research state, field by field;
  3. a seeder-born AI is DORMANT with a stable personality, enforced by NOT NULL DEFAULT + CHECK;
  4. an actionable DORMANT AI (probes, warships, colony ship, fuel, shipyard, research, a known weak foreign
     target and an active window — all asserted to be actionable) executes nothing: AI_DORMANT;
  5/6/7/8. DORMANT produces no espionage, no attack, no colonisation and no fleet movement at all;
  9. DORMANT consumes no budget: resources untouched, 0 queue rows, no activity stamp, no cooldown;
  10. the SAME AI, only with status = ACTIVE, runs the certified policy (espionage dispatched, activity stamp and
     cooldown consumed);
  11/12/13. the worker returns 0 rows for a fully DORMANT population, reaches every ACTIVE AI (3/3) and still
     rotates them (two 5-minute ticks reach different players);
  14. both birth paths delegate to the single authority (no literal quantities left) and the policy core is
     unreachable from every role.

Regression: supabase/tests/ai_behaviour_policy.sql 20 PASS and supabase/tests/ai_player_policy.sql 6 PASS still
pass. Both now explicitly activate their tested AI (documented in their headers) because the certified policy
under test requires ACTIVE — the DORMANT path is certified by the new fixture.
```


## 9. Normalising the existing AI empires (2026-09-26)

`20260926296000` fixed the BIRTH path; it could not change the 586 empires created before it (0/0/0/0 resources
and no `player_research` rows). `20260926297000_ai_empire_normalization` adds the explicit, idempotent backfill:

```text
public.normalize_existing_ai_empires(universe_id default null, limit default null, dry_run default false)
  -> (out_candidates, out_normalized, out_already_ok, out_skipped_with_progress)
```

* the endowment is applied as `SET metal = DEFAULT, crystal = DEFAULT, …`, so the single source of the initial
  quantities remains the `planet_resources` schema defaults (500/500/0/0) — no literal exists anywhere;
* initial research comes from the shared `bootstrap_new_player_state` (16 level-0 rows);
* candidates are ONLY AI empires still in the untouched legacy state; any empire with research, a building, a
  ship, a defence, a queue row, a fleet movement or non-legacy resources is skipped and counted as
  `skipped_with_progress`;
* the `status` column is never written, so every AI stays DORMANT; identity, homeworld, position and personality
  are untouched and no buildings/ships/defences are created;
* `dry_run` reports candidates without writing and `limit` allows a verified sample first — the protocol used
  before the mass LIVE operation (candidates → counts → columns → rolled-back sample → full run → verify).

LIVE result: dry run counted **586 candidates / 2 already correct / 0 with progress**; the full run normalised
**586**; the rerun reported **candidates 0 / already_ok 588** (idempotent). Post-state: 588/588 AI empires with
500/500/0/0 and 16 level-0 research rows, 0 with buildings/ships/defences, **0 ACTIVE profiles (588 DORMANT)**,
0 AI queues and 0 AI fleet movements — no AI executed any gameplay during or after the normalisation.

Beginner protection for human targets (a player inside its first 24 h cannot be attacked) is implemented by
`20260926298000` and documented in [`README_FLEET_ENGINE.md`](README_FLEET_ENGINE.md) §25. AI empires are
deliberately outside its scope: they already have the symmetric **attacker-side** 24 h gate of §7.7.

### 9.1 Every NEW AI is born with the same guarantee (verified 2026-09-27)

There is exactly **one** AI birth path: `reconcile_universe_ai_population`, invoked by
`process_universe_heartbeat` (cron every minute, `service_role` only). A schema-wide search over
`pg_proc.prosrc` confirms that it and `provision_player` are the only two functions that insert into
`public.players`, so no second birth route exists. The seeder's body contains **no occurrence of `metal`,
`crystal` or `deuterium`** and never inserts into `planet_resources`: it inserts the player, the homeworld and
then calls the shared `bootstrap_new_player_state` + `ai_ensure_player_profile`. A quantity literal therefore
cannot exist inside it, which is exactly the drift that produced the 586 legacy empires.

Measured evidence (all inside `BEGIN … ROLLBACK` unless stated):

* a forced reconciliation in a scratch universe created **3 empires**, each with `500/500/0/0` and 16 level-0
  research rows, DORMANT, no buildings/ships/defences — economics **identical** to a human provisioned in the
  same universe, including `fields_total`;
* a **second** call created 3 more, all identical: the seeder fills its density band in batches of
  `ai_generation_batch` (`LEAST(needed, batch)`), so a single call is not “one AI” but “up to one batch”;
* production: **30 AI empires born in the last 24 h were measured and all 30 are exactly in the base state**,
  0 with non-base resources, 0 without the 16 research rows, 0 without a DORMANT profile, 0 ACTIVE.

Durable guards: `supabase/tests/ai_bootstrap_and_dormant.sql` asserts that a real AI birth ≡ a real human birth
field by field; `supabase/tests/ai_normalization_and_beginner_protection.sql` assertion 15 fails if any empire
born in the last 24 h is outside the base state, and assertion 16 fails if the seeder ever regains a quantity
literal, a direct `planet_resources` insert, or if a third function starts inserting players.

## 10. ACL hardening that touches the AI engine surface (2026-09-27)

Three ACL migrations (`20260926299000`, `20260926300000`, `20260926301000`) closed the anonymous EXECUTE surface
and the internal AI-engine views. Nothing in the AI birth contract, the DORMANT state or the normalisation changed.

* the 21 engine views (`action_candidates`, `unified_action_candidates`, `next_action*`, `empire_*`,
  `optimization_candidates`, …) are no longer `anon`/`authenticated`-readable; the AI policy reaches them through
  its own SECURITY DEFINER functions (owner `postgres`), which the AI smoke assertion of
  `supabase/tests/acl_surface_p3.sql` exercises after the change;
* new functions are no longer born PUBLIC-executable: `ALTER DEFAULT PRIVILEGES … REVOKE … FROM PUBLIC` does NOT
  remove PostgreSQL's implicit PUBLIC grant (probe-verified), so a DDL event trigger
  (`trg_guard_new_function_public_execute`) revokes it on every `CREATE FUNCTION`/`CREATE PROCEDURE`;
* `ai_decide_and_act`, `run_ai_policy_worker`, the profile tables, `normalize_existing_ai_empires`,
  `get_player_attack_protection` and `bootstrap_new_player_state` keep their service_role-only ACLs.

Verified LIVE after the change: `anon`-reachable functions outside the 32-name client allow-list = **0**, no
function in `public` keeps an ACL-level PUBLIC grant, `authenticated` keeps exactly the access it had (its 32 client
RPCs plus 115 internal helpers it already reached), and the AI population is untouched: **0 ACTIVE / 588 DORMANT**,
588/588 empires with `500/500/0/0` and 16 level-0 research rows, 0 AI actions ever performed.
