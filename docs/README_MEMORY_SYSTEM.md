# DOCUMENTATION MEMORY SYSTEM — LA GRAN IMPLOSIÓN

> This document defines how persistent project knowledge is distributed across `PROJECT_CONTEXT_PROMPT.md` and specialized living documents.

## Purpose

`docs/PROJECT_CONTEXT_PROMPT.md` is the **compact operational memory** of La Gran Implosión. It must remain readable enough to recover the project quickly at the start of a session.

It is **not an encyclopedia**.

Detailed, durable knowledge should live in specialized README/documents and be referenced from the project context when needed.

## Three-layer memory model

```text
MEMORIA PERSISTENTE DE CHATGPT
        ↓
PROJECT_CONTEXT_PROMPT.md
        ↓
DOCUMENTOS ESPECIALIZADOS
        ↓
CÓDIGO REAL + SUPABASE
```

### 1. Persistent ChatGPT memory

Stores durable continuity: important project decisions, working principles, long-lived preferences and cross-session context.

### 2. `docs/PROJECT_CONTEXT_PROMPT.md`

Stores the minimum operational context required to continue development safely:

- current state;
- active decisions;
- OPEN / CLOSED / SUPERSEDED work;
- canonical terminology;
- current roadmap;
- source-of-truth hierarchy;
- development workflow;
- links/index to specialized documents.

### 3. Specialized living documents

Store detailed knowledge that remains useful but does not need to be loaded into the operational context on every task.

Examples:

```text
docs/reference/README_OGAMEX.md
docs/architecture/README_ARCHITECTURE.md
docs/systems/README_UNIVERSE_EVOLUTION.md
docs/systems/README_COMBAT.md
docs/systems/README_ECONOMY.md
docs/systems/README_FLEET.md
docs/tools/README_DEVELOPMENT_WORKFLOW.md
```

Directories may grow as the project grows. Do not create a document merely to split a few lines; split when a subject has enough durable knowledge to benefit from independent maintenance.

## Routing rule

When new information is discovered, classify it before documenting it:

```text
Is it required to understand where the project is NOW?
        │
        ├── YES → PROJECT_CONTEXT.md
        │
        └── NO
             ↓
Does it remain useful as durable project knowledge?
        │
        ├── YES → relevant specialized document
        │
        └── NO → session-only knowledge
```

If a subject is important to both levels, keep only a **compact operational summary** in `PROJECT_CONTEXT.md` and put the detail in the specialized document.

## Never delete useful knowledge just to shorten `PROJECT_CONTEXT.md`

When the context becomes too large:

1. identify detailed sections that are still useful;
2. move their durable detail into a specialized document;
3. replace the moved detail in `PROJECT_CONTEXT.md` with a concise summary and link/index entry;
4. preserve the canonical decision and current status in `PROJECT_CONTEXT.md`;
5. only propose actual deletion when information is obsolete, duplicated or demonstrably useless.

This preserves project knowledge while optimizing operational context.

## Status and authority

Specialized documents are **living project documentation**, not independent sources of truth.

When a specialized document conflicts with live code/database state, the project source-of-truth hierarchy applies. Update the document after verification.

Use explicit status markers where useful:

```text
OPEN
CLOSED
SUPERSEDED
REFERENCE
```

Historical decisions should normally remain traceable when they explain why the current architecture exists.

## Update protocol

After a substantial task:

```text
1. Verify implementation/state.
2. Decide whether the discovery changes operational context.
3. Update PROJECT_CONTEXT.md only for operationally important changes.
4. Update the relevant specialized document with durable detail.
5. If no specialized document exists and the knowledge is durable, create one.
6. Keep terminology and status synchronized.
```

## Session recovery protocol

At the start of a new project session:

```text
MEMORY
  ↓
PROJECT_CONTEXT.md
  ↓
Identify task/domain
  ↓
Open only the relevant specialized document(s)
  ↓
Inspect current GitHub/Supabase state
  ↓
Work
```

Do not load every specialized document by default.

## Current document index

| Document | Purpose | Status |
|---|---|---|
| `docs/PROJECT_CONTEXT_PROMPT.md` | Compact operational memory and roadmap | CANONICAL OPERATIONAL CONTEXT |
| `docs/reference/README_OGAMEX.md` | OGameX reference/pattern map | REFERENCE |
| `docs/architecture/README_ARCHITECTURE.md` | Durable L.G.I. architecture decisions | LIVING |
| `docs/systems/README_UNIVERSE_EVOLUTION.md` | Universe evolution and expansion knowledge | LIVING |
| `docs/systems/README_OWNERSHIP_HARDENING.md` | Owned RPC authorization and hardening evidence | LIVING / CLOSED |
| `docs/tools/README_DEVELOPMENT_WORKFLOW.md` | Cline/Qwen/Copilot/GitHub/Supabase workflow | LIVING |

Add future system-specific documents to this index when they become substantial enough to justify separation.
