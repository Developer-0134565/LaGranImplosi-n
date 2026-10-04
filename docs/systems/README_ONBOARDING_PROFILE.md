# Onboarding, account profile and initial preferences

**Status source:** implementation report from the 2026-10-03/04 local development session. The report states that the changes were not committed, pushed or deployed. This document records the reported implementation and must not be treated as proof that the public Worker deployment contains it.

## Planet name

- Optional field: planets.planet_name.
- Empty value displays as **Homeworld**.
- Maximum length: 32 characters.
- No global uniqueness constraint: coordinates identify planets, so different empires may use the same display name.
- Invalid input is normalized to NULL; provisioning must still succeed. A cosmetic name must never block player creation.

## Avatar

- players.avatar_id selects one of 12 procedural SVG emblems.
- SVGs are generated/rendered by the shared renderAvatar() path; no external image payload is required.
- These are procedural lore-style emblems, **not AI-generated raster images**.
- If raster artwork is introduced later, keep the rendering replacement localized to renderAvatar(); do not change identity or ownership semantics.

## Language preference

Supported languages: es, en, ru.

Default selection reported by the implementation:
- Spanish-speaking country → es.
- English-speaking country → en.
- Russia → ru.
- Any other or unknown country → en.

Country detection uses the existing Cloudflare Worker /api/visitor response. A saved localStorage preference takes precedence over IP-derived country detection.

The auth UI package @supabase/auth-ui-react does not provide the required locale prop/dictionaries for this use; the implementation supplies the relevant strings directly. The report records 27 country/fallback cases passing.

**Translation scope caveat:** login, onboarding and language selector were translated. Approximately 180 strings in gameplay panels (including GameplayEnginePanel, FleetModules and MoonServicesPanel) were still Spanish-only in the report. Do not claim the whole game is translated.

## Email confirmation and provisioning

- Existing email confirmation was already valid; no change to the confirmation policy was reported.
- magicLink={false} was used to remove the magic-link path that pointed to localhost.
- Two overloaded provision_player signatures (2-arg and 4-arg) caused PostgREST ambiguity; the obsolete 2-arg overload was removed, leaving one canonical 4-arg contract.

## Verification and deployment boundary

The report states:
- LIVE DEV diagnostic state: 0 players, 0 planets; the test email was confirmed (personal address intentionally not recorded here).
- TypeScript clean; build successful; lint 0 errors with 7 pre-existing warnings.
- 27 language-detection cases passed.
- Changes were **not deployed and not committed/pushed** in the source session.
- Manual Supabase Auth Dashboard Site URL correction to https://lagranimplosion.lagranimplosion.workers.dev and deployment were still pending.

Before treating this as deployed, verify the actual GitHub source, migration/catalogue state where applicable, Supabase Auth URL configuration, and the live Worker. Do not infer deployment from this document.
