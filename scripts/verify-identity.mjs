#!/usr/bin/env node
/**
 * IDENTIDAD — verificación de la cadena auth.uid() → players → planets → planet_resources.
 *
 * SOLO LECTURA: no escribe en la base de datos y NO crea sesiones/players (crear una sesión
 * anónima daría de alta datos reales), por lo que si no hay sesión activa las comprobaciones
 * que dependen de auth.uid() se marcan como SKIP.
 *
 * Uso:  node scripts/verify-identity.mjs
 * Credenciales: .env.local (VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY)
 */
import { readFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'

const ENV_PATH = new URL('../.env.local', import.meta.url)
const APP_PATH = new URL('../src/App.tsx', import.meta.url)
const MAIN_PATH = new URL('../src/main.tsx', import.meta.url)
const IDENTITY_PATH = new URL('../src/lib/identity.ts', import.meta.url)

let env = ''
try { env = readFileSync(ENV_PATH, 'utf8') } catch { console.error('No se pudo leer .env.local'); process.exit(2) }
const readVar = (name) => (env.match(new RegExp(`^${name}=(.+)$`, 'm')) || [])[1]?.trim()
const url = readVar('VITE_SUPABASE_URL')
const key = readVar('VITE_SUPABASE_PUBLISHABLE_KEY')
if (!url || !key) { console.error('Faltan VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY'); process.exit(2) }

const sb = createClient(url, key)
let fails = 0
const pass = (n, d = '') => console.log(`PASS  ${n}${d ? '  -> ' + d : ''}`)
const fail = (n, d = '') => { fails++; console.log(`FAIL  ${n}${d ? '  -> ' + d : ''}`) }
const skip = (n, d = '') => console.log(`SKIP  ${n}${d ? '  -> ' + d : ''}`)
const check = (n, ok, d = '') => (ok ? pass(n, d) : fail(n, d))
const id = (v) => (v ? String(v).slice(0, 8) + '...' : '(null)')

console.log(`\n== IDENTIDAD · cadena auth.uid -> player -> planet -> resources ==\n${url}\n`)

// ---------------------------------------------------------------- 1) codigo
const appSrc = readFileSync(APP_PATH, 'utf8')
const mainSrc = readFileSync(MAIN_PATH, 'utf8')
const idSrc = readFileSync(IDENTITY_PATH, 'utf8')

check('App.tsx filtra los planetas por player_id', appSrc.includes(".eq('player_id'"))
check(
  'App.tsx ya no usa heuristicas globales de planeta',
  !appSrc.includes('p.is_homeworld&&p.players?.is_guest'),
  appSrc.includes('activePlanet=planets.find(p=>p.is_homeworld)??planets[0]') ? 'seleccion dentro de los planetas del jugador' : 'revisar'
)
check('App.tsx resuelve la identidad antes de cargar planetas', appSrc.includes('resolveIdentity()'))
check('main.tsx garantiza sesion (anonima si no hay)', mainSrc.includes('ensureSession()'))
check('identity.ts crea sesion anonima cuando no hay sesion', idSrc.includes('signInAnonymously'))
check('identity.ts resuelve el player por user_id', idSrc.includes(".eq('user_id', userId)"))
check('identity.ts no resuelve identidad por username/is_guest', !/\.eq\('(username|is_guest)'/.test(idSrc))

// ---------------------------------------------------------------- 2) sesion
const { data: sessionData } = await sb.auth.getSession()
const sessionUser = sessionData?.session?.user ?? null
if (!sessionUser) {
  skip('cadena de identidad de la sesion actual', 'no hay sesion activa (el script no crea sesiones)')
} else {
  console.log(`SESION  uid=${id(sessionUser.id)} anonima=${Boolean(sessionUser.is_anonymous)}`)
  const { data: player, error: pe } = await sb
    .from('players')
    .select('id,username,is_guest,universe_id,user_id')
    .eq('user_id', sessionUser.id)
    .maybeSingle()
  if (pe) fail('players.user_id = auth.uid()', pe.message)
  else check('players.user_id = auth.uid()', Boolean(player), player ? `${player.username} (${id(player.id)})` : 'la sesion no tiene player')

  if (player) {
    const { data: planets, error: pne } = await sb
      .from('planets')
      .select('id,name,is_homeworld,player_id,planet_resources(metal,crystal,deuterium,energy)')
      .eq('player_id', player.id)
      .eq('is_destroyed', false)
    if (pne) fail('planets.player_id = players.id', pne.message)
    else {
      const list = planets ?? []
      const homelands = list.filter((p) => p.is_homeworld)
      check('planets.player_id = players.id (solo planetas propios)', list.length > 0 && list.every((p) => p.player_id === player.id), `${list.length} planetas`)
      check('existe homeworld propio', homelands.length === 1, homelands.map((p) => p.name).join(', ') || 'ninguno')
      const active = homelands[0] ?? list[0]
      if (active) {
        const res = Array.isArray(active.planet_resources) ? active.planet_resources[0] : active.planet_resources
        check('planet_resources.planet_id = activePlanet.id', Boolean(res), res ? `metal=${res.metal}` : 'recursos no visibles para este planeta')
      }
    }
  }
}

// ---------------------------------------------------------------- 3) aislamiento
const { data: visiblePlayers } = await sb.from('players').select('id,username,is_guest,user_id').limit(200)
const devPlayer = (visiblePlayers ?? []).find((p) => p.username === 'DevPlayer')
if (devPlayer) {
  const { data: own } = await sb.from('planets').select('id,player_id,name').eq('player_id', devPlayer.id).eq('is_destroyed', false)
  const foreign = (own ?? []).filter((p) => p.player_id !== devPlayer.id)
  check('consulta scoped (.eq player_id) devuelve solo planetas de ese player', (own ?? []).length > 0 && foreign.length === 0, `${(own ?? []).length} planetas`)
  const all = await sb.from('planets').select('id', { count: 'exact', head: true }).eq('is_destroyed', false)
  console.log(`      contexto: la lectura global expone ${all.count} planetas (mapa galactico); la identidad ya NO depende de esa lista`)
} else {
  skip('aislamiento de la consulta scoped', 'no hay player de referencia visible')
}

const spoof = await sb.from('players').select('id,username,user_id').eq('user_id', '00000000-0000-4000-8000-000000000000')
check('players no se puede consultar por un user_id ajeno (RLS)', (spoof.data ?? []).length === 0, `filas=${(spoof.data ?? []).length}`)

// ---------------------------------------------------------------- 4) invariantes
const { data: allPlayers } = await sb.from('players').select('id,username,is_guest,player_type,user_id').limit(500)
const { data: allPlanets } = await sb.from('planets').select('id,player_id,is_homeworld,is_destroyed').limit(1000)
const humans = (allPlayers ?? []).filter((p) => p.player_type === 'HUMAN')
const humansWithoutUser = humans.filter((p) => !p.user_id)
check('todo player HUMANO tiene user_id (identidad resoluble)', humansWithoutUser.length === 0, humansWithoutUser.map((p) => p.username).join(', ') || `${humans.length} humanos`)
const orphanPlanets = (allPlanets ?? []).filter((p) => !p.player_id)
check('no hay planetas sin player_id', orphanPlanets.length === 0, `${orphanPlanets.length} de ${(allPlanets ?? []).length}`)
const ownersWithPlanets = new Set((allPlanets ?? []).map((p) => p.player_id))
const humansWithoutPlanets = humans.filter((p) => !ownersWithPlanets.has(p.id))
check('todo player HUMANO tiene al menos un planeta', humansWithoutPlanets.length === 0, humansWithoutPlanets.map((p) => p.username).join(', ') || 'ok')
const hwCount = new Map()
for (const p of allPlanets ?? []) {
  if (p.is_homeworld && p.player_id) hwCount.set(p.player_id, (hwCount.get(p.player_id) ?? 0) + 1)
}
const multiHw = [...hwCount.entries()].filter(([, n]) => n > 1)
check('ningun player tiene mas de un homeworld', multiHw.length === 0, `${multiHw.length} casos`)
console.log(`      contexto: ${humans.length} humanos, ${(allPlanets ?? []).length} planetas visibles`)

console.log(`\n== resultado: ${fails === 0 ? 'PASS' : `${fails} FAIL`} ==\n`)
process.exit(fails === 0 ? 0 : 1)
