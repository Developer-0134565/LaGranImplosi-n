// Contract inventory probe (read-only, static analysis of src/**).
// Walks every .ts/.tsx and collects every Supabase RPC name and table name the browser can call,
// so the backend<->UI diff for the gap sweep is derived, never remembered.
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2).filter((a) => !a.startsWith('--'))
const root = path.resolve(args[0] || 'src')
const names = new Map() // name -> Set(files)
const tableNames = new Map()

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full)
    else if (/\.(ts|tsx)$/.test(entry.name)) scan(full)
  }
}

function add(map, name, file) {
  if (!map.has(name)) map.set(name, new Set())
  map.get(name).add(path.relative(process.cwd(), file).replace(/\\/g, '/'))
}

/* The RPC name is not always a string literal at the call site: `App.tsx` dispatches the four
   production starters through a computed variable —

       const rpc = type==='building' ? 'start_building'
                  : type==='research' ? 'start_research'
                  : type==='ship'     ? 'start_ship'
                  :                     'start_defense';
       const { error } = await supabase.rpc(rpc, args)

   A literal-only scan therefore reported NONE of the four as client-called, while they are the
   contracts behind buildings, research, shipyard and defence. That is a FALSE NEGATIVE, and this
   tool is the mechanical justification for revoking `authenticated` EXECUTE ("no client caller"),
   so an under-report can authorise revoking a live gameplay dispatcher.

   Resolution is deliberately an OVER-approximation: when a call site passes a variable instead of
   a literal, every branch value of that variable's declaration is added. Over-reporting can only
   make a future revocation more conservative, which is the safe direction; under-reporting is the
   dangerous one. Literals that are only *compared against* (`type==='building'`) are discarded so
   the extra names stay meaningful instead of polluting the inventory with UI discriminant words. */
function resolveIndirectRpcNames(src) {
  const resolved = new Map() // variable -> string[]
  const declRe = /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]+)/g
  let d
  while ((d = declRe.exec(src))) {
    const [, variable, initializer] = d
    if (!/'[a-z0-9_]+'|"[a-z0-9_]+"/.test(initializer)) continue
    const branches = []
    const litRe = /(['"])([a-z0-9_]+)\1/g
    let l
    while ((l = litRe.exec(initializer))) {
      const before = initializer.slice(0, l.index)
      /* keep only branch values, not the operands of a comparison */
      if (/(?:===|!==|==|!=)\s*$/.test(before)) continue
      branches.push(l[2])
    }
    if (branches.length) resolved.set(variable, branches)
  }
  const names = []
  for (const [variable, branches] of resolved) {
    const useRe = new RegExp(`\\.rpc\\(\\s*${variable}\\b|\\brpcUntyped\\(\\s*${variable}\\b|\\brpcName\\(\\s*${variable}\\b`, 'g')
    if (useRe.test(src)) names.push(...branches)
  }
  return names
}

function scan(file) {
  const src = fs.readFileSync(file, 'utf8')
  src.split(/\r?\n/).forEach((line) => {
    for (const re of [
      /\.rpc\(\s*['"]([a-z0-9_]+)['"]/g,
      /rpcUntyped\(\s*['"]([a-z0-9_]+)['"]/g,
      /rpcName\(\s*['"]([a-z0-9_]+)['"]/g
    ]) {
      let m
      while ((m = re.exec(line))) add(names, m[1], file)
    }
    let t
    const tre = /\.from\(\s*['"]([a-z0-9_]+)['"]\s*\)/g
    while ((t = tre.exec(line))) add(tableNames, t[1], file)
  })
  for (const name of resolveIndirectRpcNames(src)) add(names, name, file)
}

walk(root)
const toList = (m) =>
  [...m.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([n, f]) => `${n}\t${[...f].join(',')}`)

if (process.argv.includes('--names-only')) {
  console.log([...names.keys()].sort().join('\n'))
  process.exit(0)
}

console.log('=== RPC NAMES (src) ===')
console.log(toList(names).join('\n'))
console.log('\n=== TABLE NAMES (src) ===')
console.log(toList(tableNames).join('\n'))

/* ---- REGRESSION (2026-09-29, indirect RPC dispatch) --------------------------------------
   The inventory is the mechanical evidence used to decide that a contract has "no client caller"
   and may therefore lose its `authenticated` EXECUTE grant (see 20260929014633). A literal-only
   scan silently missed the four production starters because `App.tsx` selects the RPC name through
   a variable, so the tool under-reported exactly the contracts that must never be revoked.

   This guard fails loudly instead of letting the inventory drift back into an unsound state. It is
   self-contained: it re-derives the inventory in-process and asserts the invariant, so it needs no
   database and no network. */
if (process.argv.includes('--assert-client-dispatchers')) {
  /* Contracts whose revocation would break a playable loop (buildings / research / shipyard /
     defence) and which the client reaches INDIRECTLY, through a computed `.rpc(<variable>)`. */
  const required = ['start_building', 'start_research', 'start_ship', 'start_defense']
  const missing = required.filter((n) => !names.has(n))
  /* A positive control: if this ever disappears the guard itself is broken, not the inventory. */
  const control = ['can_start_building', 'can_start_research', 'can_build_ship', 'can_build_defense']
  const controlMissing = control.filter((n) => !names.has(n))
  const noisy = [...names.keys()].filter((n) => ['building', 'research', 'ship', 'defense'].includes(n))
  if (missing.length || controlMissing.length || noisy.length) {
    if (missing.length) console.error(`FAIL  client dispatchers not in the inventory: ${missing.join(', ')}`)
    if (controlMissing.length) console.error(`FAIL  control names not in the inventory: ${controlMissing.join(', ')}`)
    if (noisy.length) console.error(`FAIL  comparison operands leaked into the inventory: ${noisy.join(', ')}`)
    process.exit(1)
  }
  console.log(
    `PASS  indirect client dispatchers detected (${required.join(', ')}); ` +
      `${names.size} RPC names total, no comparison operands leaked`
  )
}
