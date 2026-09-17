# DEVELOPMENT WORKFLOW — LA GRAN IMPLOSIÓN

## Purpose

Detailed durable description of how the project's tools cooperate. Keep `PROJECT_CONTEXT.md` focused on the compact operational rules.

## Tool responsibilities

| Tool | Role |
|---|---|
| Persistent memory | Cross-session continuity and durable project principles |
| `PROJECT_CONTEXT.md` | Compact operational context, status and roadmap |
| Specialized docs | Detailed durable domain/tool knowledge |
| ChatGPT | Architecture, audit, design, coordination and review |
| OGameX | External pattern/reference library |
| Cline | Repository-level implementation agent |
| Qwen + LM Studio | Local execution/reasoning resource used with the development workflow |
| Copilot | Scoped implementation and mechanical refactoring |
| Supabase | Live backend/game-state authority |
| GitHub | Code, migrations and documentation authority |
| DeepSeek | Optional secondary reasoning aid; never authoritative |

## Standard development loop

```text
MEMORY + PROJECT_CONTEXT
        ↓
RECOVER CURRENT STATE
        ↓
AUDIT REAL L.G.I.
        ↓
CHECK RELEVANT SPECIALIZED DOCS
        ↓
CHECK OGameX WHEN A CONCEPTUAL EQUIVALENT EXISTS
        ↓
DEFINE L.G.I.-SPECIFIC DESIGN
        ↓
CREATE BOUNDED IMPLEMENTATION TASK
        ↓
CLINE + QWEN / COPILOT
        ↓
BUILD / TEST / CHECK
        ↓
AUDIT IMPLEMENTATION
        ↓
VERIFY GITHUB + SUPABASE INTEGRATION
        ↓
UPDATE SPECIALIZED DOC
        ↓
UPDATE PROJECT_CONTEXT ONLY IF OPERATIONAL STATE CHANGED
        ↓
UPDATE PERSISTENT MEMORY WHEN DURABLE CROSS-SESSION CONTEXT CHANGED
```

## Bounded task protocol

Every task given to an implementation agent should state:

```text
SCOPE
FILES / AREAS
DO NOT TOUCH
KNOWN CANONICAL FUNCTIONS/TABLES
EXPECTED RESULT
VALIDATION
```

Agents receive the interpreted L.G.I. specification. They should not be instructed to reproduce an external repository.

## Change-documentation rule

A change can affect three documentation levels differently:

```text
Implementation detail only
→ specialized document if durable; otherwise no context change

Operational state / active decision
→ PROJECT_CONTEXT.md

Long-lived cross-session principle
→ persistent memory
```

## Maintenance rule

Do not duplicate the same detailed explanation across multiple documents. Keep one canonical detailed location and reference it from shorter operational documents.


## Agent audit cost-control protocol

The first DeepSeek/Cline recognition audit demonstrated that an unrestricted repository-wide prompt can consume a very large context budget (the observed first run processed approximately 1.39 million tokens). That cost is acceptable only for an exceptional initial mapping when the project is otherwise poorly understood; it is not the normal audit pattern.

### Required prompt discipline

Before every Cline prompt, explicitly state:

- Intelligence: None / Low / Medium / High / Extra
- Expected cost: LOW / MEDIUM / HIGH
- Why: one short sentence

Recommended use: None for mechanical/trivial changes; Low for simple bounded implementation; Medium for recognition, small audits and ordinary bounded tasks; High for deep subsystem audits and architecture-sensitive work; Extra only for exceptional maximum-difficulty analysis.

### Initial vs directed audits

```text
INITIAL RECOGNITION
→ broad enough to map the project once

DIRECTED AUDIT
→ only known subsystem/files/functions
→ no repository-wide rediscovery
→ concise structured output

IMPLEMENTATION
→ exact files/areas
→ explicit DO NOT TOUCH
→ no architecture invention

VERIFICATION
→ targeted tests/diffs/database checks
```

Once the initial map exists, do not ask an agent to rediscover the entire repository unless a concrete change in repository structure makes that necessary.

### Output-size discipline

Audits should prefer tables, exact file/function names, formulas, short evidence excerpts, explicit contradictions and bounded conclusions. Avoid exhaustive file dumps, repeated architecture summaries, unrelated system explanations and speculative redesigns during read-only audits.

### DeepSeek role

DeepSeek is a reasoning/execution aid inside the workflow, not a source of truth. Live Supabase state, current GitHub code/migrations and verified project documentation remain authoritative according to the project source-of-truth hierarchy.

### 2026-09-17 observation

The first recognition audit found two overlapping local repository copies, substantial Git/production migration drift, an existing PostgreSQL universe-evolution engine, and active production cron jobs. Future work should exploit that map rather than pay for another global scan.
