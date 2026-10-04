// Repo-vs-LIVE migration drift report (READ-ONLY: it writes nothing and changes nothing).
//
// The LIVE ledger (supabase_migrations.schema_migrations) is the authority for what was actually
// applied. This compares the recent window of supabase/migrations/*.sql against it and classifies
// every difference. It deliberately proposes NO ledger write: repairing the ledger from this copy is
// forbidden by the project, so the only permitted remediation is renaming a REPO FILE to match an
// existing ledger row.
//
// Refresh the LIVE map with:  select version, name from supabase_migrations.schema_migrations order by version;

import fs from 'node:fs'

const LIVE = JSON.parse(fs.readFileSync(new URL('./migration-ledger-snapshot.json', import.meta.url), 'utf8'))

const dir = 'supabase/migrations'
const FLOOR = 20260926000000
const repo = new Map() // version -> basename
for (const f of fs.readdirSync(dir)) {
  const m = f.match(/^(\d{14})_(.+)\.sql$/)
  if (!m || Number(m[1]) < FLOOR) continue
  repo.set(Number(m[1]), f)
}

const repoVersions = new Set(repo.keys())
const liveVersions = new Set(Object.keys(LIVE).map(Number))
const liveByName = new Map(Object.entries(LIVE).map(([v, n]) => [n, Number(v)]))
const repoByName = new Map([...repo].map(([v, f]) => [f.replace(/^\d{14}_/, '').replace(/\.sql$/, ''), v]))

const repoOnly = [...repoVersions].filter((v) => !liveVersions.has(v)).sort((a, b) => a - b)
const liveOnly = [...liveVersions].filter((v) => !repoVersions.has(v)).sort((a, b) => a - b)
const renames = []
for (const [name, liveV] of liveByName) {
  if (repoByName.has(name) && repoByName.get(name) !== liveV) renames.push({ name, repo: repoByName.get(name), live: liveV })
}
const counts = new Map()
for (const n of Object.values(LIVE)) counts.set(n, (counts.get(n) || 0) + 1)

const matched = [...repoVersions].filter((v) => liveVersions.has(v)).length
console.log(`window (>= ${FLOOR})   repo files=${repo.size}  LIVE rows=${liveVersions.size}  exact match=${matched}`)
console.log(`\nA. repo version with NO LIVE row (${repoOnly.length}) - unapplied, or already resolved by C:`)
for (const v of repoOnly) console.log(`   repo ${v}  ${repo.get(v)}`)
console.log(`\nB. LIVE row with NO repo file (${liveOnly.length}):`)
for (const v of liveOnly) console.log(`   LIVE ${v}  ${LIVE[v]}`)
console.log(`\nC. same name, DIFFERENT version (${renames.length}) - rename the repo file to the LIVE version:`)
for (const r of renames) console.log(`   ${r.name}\n      repo ${r.repo}  ->  LIVE ${r.live}`)
console.log(`\nD. a name applied more than once in the LIVE ledger:`)
for (const [n, c] of counts) if (c > 1) console.log(`   ${n} x${c}`)
console.log(`\n(ledger total rows in DB: 388, oldest 20260912092555, newest ${Math.max(...liveVersions)})`)
