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
