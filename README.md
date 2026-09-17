# La Gran Implosión

OGame-like browser game built with React + TypeScript + Vite and Supabase.

## Project operating rules

- **Supabase is authoritative for the live game state.**
- **GitHub is authoritative for application code and checked-in migrations/docs.**
- Do not invent historical migrations to make repository and production migration counts match.
- Do not make destructive production changes merely to clean up history.
- Gameplay architecture and formulas are designed deliberately before mechanical implementation.
- Copilot may perform scoped implementation/refactor work, but must not invent game mechanics.
- Before any substantial change, read `docs/PROJECT_CONTEXT_PROMPT.md` and the relevant living monitor documents.

## Current architecture priorities

1. Stable player → active planet → universe state contract.
2. Universe evolution as a time-dependent state, separate from galaxy/system expansion.
3. Centralized universe scaling through `calculate_universe_scaling(E)`.
4. Centralized fleet movement/travel-time calculation.
5. Explicit modifier ordering so future technologies, items, events and other buffs do not become hidden evolution logic.
6. Security/RLS hardening remains a final-phase concern unless a current change explicitly requires it.

## Living project documentation

- `docs/PROJECT_CONTEXT_PROMPT.md` — canonical context and anti-duplication prompt. Read this first.
- `docs/UNIVERSE_RATE_AND_FLEET_ENGINE_MONITOR.md` — canonical rate/scaling and fleet-movement monitor.
- `docs/PRODUCTION_DB_BASELINE.md` — production database/source-of-truth baseline and reproducibility status.

## Development

```bash
npm install
npm run dev
npm run build
npm run lint
```

The repository may contain local development artifacts that are intentionally outside the committed application architecture. Do not delete or alter them without auditing their purpose first.
