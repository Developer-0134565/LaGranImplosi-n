# Responsive shell and navigation CSS

**Status source:** local implementation/audit report dated 2026-10-04. The report explicitly says no deployment occurred and the public site remained unchanged until the code is published/deployed. This document records the diagnosis and verification design, not proof of live deployment.

## Root cause and fix

The vertical navigation defect was caused by the absence of a CSS rule for the .neo-nav container. The browser therefore laid out its inline-block buttons as inline text, allowing them to wrap into two columns.

Canonical desktop layout:

~~~css
.neo-nav {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.neo-nav-item {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  text-align: left;
}
~~~

At widths **≤760px**, the navigation intentionally becomes a horizontal strip; preserve an explicit mobile override rather than applying the desktop column rule indiscriminately.

A second presentation defect came from missing rules for .neo-brand and .neo-player; their child label/value elements need block layout so adjacent text does not run together.

## Dead CSS / false hypothesis

The report corrected an earlier false diagnosis: max-width: 1440px on .neo-shell was not constraining the real shell. It belonged to dead CSS for a removed TemplateChrome. The active shell was reported as .lgi-live-shell > .lgi-layout; the dead rule was removed in the local change.

The project uses its own design system; the report found no Tailwind, MUI or Bootstrap dependency and no encoding corruption in the inspected 148 files.

## Regression harness lesson

A previous headless audit passed 42/42 combinations (6 templates × 7 viewports) while the navigation defect was present. That audit did not test the actual geometric shape of the navigation.

The revised harness adds a structural assertion:
- navigation items share the same left;
- each successive item has a greater top;
- each item width matches its container.

A negative control deliberately injects the broken layout and must emit [BUG] and exit with code 1. A passing test without a failing negative control is insufficient evidence that the assertion detects the defect.

## Verification limits

The harness measures the CSS cascade on a DOM fixture faithful to UIEngineScreen; it is not a full authenticated application session with real Supabase data. The report lacked DEV credentials for that separate check.

Reported static results: TypeScript exit 0, build exit 0, lint 0 errors (7 pre-existing warnings), git diff --check exit 0.

**Deployment:** not performed in the source session. Do not claim the public site has the fix until the corresponding code is in GitHub and the Worker is deployed.
