#!/usr/bin/env node
/**
 * BUILDINGS — verificación en vivo de SOLO LECTURA (no modifica la base de datos).
 *
 * Comprueba contra la Supabase viva:
 *   1. definiciones de edificios y sus factores
 *   2. coste autoritativo (calculate_building_cost) contra el oráculo base*factor^(n-1)
 *   3. contrato completo de can_start_building y coherencia de coste con el nivel objetivo
 *   4. rama de "recursos insuficientes" (si hay un planeta visible con pocos recursos)
 *   5. invariantes de datos: cola activa única por planeta y niveles persistidos
 *   6. motor de producción autoritativo y helpers de proyección (documenta la divergencia)
 *
 * Uso:  node scripts/verify-buildings.mjs [planetId]
 * Credenciales: .env.local (VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY)
 *
 * Los caminos de ESCRITURA (start/complete/doble completado/recursos) se prueban en
 * supabase/tests/buildings_lifecycle.sql, que es transaccional y no commitea.
 */
import { readFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'

const ENV_PATH = new URL('../.env.local', import.meta.url)
let env = ''
try { env = readFileSync(ENV_PATH, 'utf8') } catch { console.error('No se pudo leer .env.local'); process.exit(2) }
const readVar = (name) => (env.match(new RegExp(`^${name}=(.+)$`, 'm')) || [])[1]?.trim()
const url = readVar('VITE_SUPABASE_URL')
const key = readVar('VITE_SUPABASE_PUBLISHABLE_KEY')
if (!url || !key) { console.error('Faltan VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY en .env.local'); process.exit(2) }

const sb = createClient(url, key)
let fails = 0
const pass = (name, detail = '') => console.log(`PASS  ${name}${detail ? '  -> ' + detail : ''}`)
const fail = (name, detail = '') => { fails++; console.log(`FAIL  ${name}${detail ? '  -> ' + detail : ''}`) }
const skip = (name, detail = '') => console.log(`SKIP  ${name}${detail ? '  -> ' + detail : ''}`)
const check = (name, ok, detail = '') => (ok ? pass(name, detail) : fail(name, detail))

console.log(`\n== BUILDINGS · verificacion en vivo (solo lectura) ==\n${url}\n`)

// 1) definiciones
const { data: defs, error: defsErr } = await sb
  .from('building_definitions')
  .select('id,name,base_metal,base_crystal,base_deuterium,cost_factor,base_build_time_seconds,time_factor,max_level')
  .order('id')
check('definiciones legibles', !defsErr && (defs?.length ?? 0) > 0, defsErr ? defsErr.message : `${defs?.length ?? 0} edificios`)
check('todas las definiciones tienen factores de coste y tiempo', (defs ?? []).every(d => Number(d.cost_factor) > 0 && Number(d.time_factor) > 0))

// 2) coste autoritativo vs oraculo
let costOk = true, costDetail = ''
for (const d of defs ?? []) {
  for (const level of [1, 2, 3]) {
    const { data, error } = await sb.rpc('calculate_building_cost', { p_building_id: d.id, p_target_level: level })
    if (error) { costOk = false; costDetail = `${d.id} n${level}: ${error.message}`; break }
    const row = data?.[0]
    const f = Math.pow(Number(d.cost_factor), level - 1)
    const expected = [Number(d.base_metal) * f, Number(d.base_crystal) * f, Number(d.base_deuterium) * f]
    const got = [Number(row?.metal), Number(row?.crystal), Number(row?.deuterium)]
    if (!expected.every((v, i) => Math.abs(v - got[i]) < 1e-6)) {
      costOk = false; costDetail = `${d.id} n${level}: esperado ${expected.join('/')} obtenido ${got.join('/')}`; break
    }
  }
  if (!costOk) break
}
check('calculate_building_cost = base·factor^(n-1)', costOk, costDetail)

// 3) planeta objetivo
const planetArg = process.argv[2]
let planet = null
if (planetArg) {
  const { data } = await sb.from('planets').select('id,name,universe_id,player_id,fields_used,fields_total').eq('id', planetArg).maybeSingle()
  planet = data
} else {
  const { data: rows } = await sb.from('planet_buildings').select('planet_id,level').order('level', { ascending: false }).limit(50)
  const counts = new Map()
  for (const r of rows ?? []) counts.set(r.planet_id, (counts.get(r.planet_id) ?? 0) + 1)
  const best = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0]
  if (best) {
    const { data } = await sb.from('planets').select('id,name,universe_id,player_id,fields_used,fields_total').eq('id', best).maybeSingle()
    planet = data
  }
}

if (!planet) {
  fail('planeta de prueba resoluble', 'pasa un planetId por argumento')
} else {
  console.log(`PLANETA  ${planet.name} · ${planet.id} · campos ${planet.fields_used}/${planet.fields_total}`)

  // 4) contrato de can_start_building
  let contractOk = true, contractDetail = ''
  for (const d of defs ?? []) {
    const { data, error } = await sb.rpc('can_start_building', { p_player_id: planet.player_id, p_planet_id: planet.id, p_building_id: d.id })
    if (error) { contractOk = false; contractDetail = `${d.id}: ${error.message}`; break }
    const info = data?.[0]
    if (!info || typeof info.allowed !== 'boolean' || !info.reason || Number(info.target_level) !== Number(info.current_level) + 1) {
      contractOk = false; contractDetail = `${d.id}: contrato incompleto ${JSON.stringify(info)}`; break
    }
    const { data: cost } = await sb.rpc('calculate_building_cost', { p_building_id: d.id, p_target_level: info.target_level })
    const c = cost?.[0]
    if (Number(info.cost_metal) !== Number(c?.metal) || Number(info.cost_crystal) !== Number(c?.crystal) || Number(info.cost_deuterium) !== Number(c?.deuterium)) {
      contractOk = false; contractDetail = `${d.id}: coste del contrato != calculate_building_cost`; break
    }
  }
  check('can_start_building: contrato completo y coste autoritativo del siguiente nivel', contractOk, contractDetail)

  const { data: sample } = await sb.rpc('can_start_building', { p_player_id: planet.player_id, p_planet_id: planet.id, p_building_id: 'metal_mine' })
  const first = sample?.[0]
  console.log(`      muestra: allowed=${first?.allowed} reason="${first?.reason}" nivel ${first?.current_level}->${first?.target_level} coste ${first?.cost_metal}/${first?.cost_crystal}/${first?.cost_deuterium} disponible ${first?.available_metal}/${first?.available_crystal}/${first?.available_deuterium}`)

  // 5) rama de recursos insuficientes
  const { data: planets } = await sb.from('planets').select('id,name,player_id').eq('is_destroyed', false).limit(120)
  let lowCase = null
  for (const p of planets ?? []) {
    const { data: res } = await sb.from('planet_resources').select('metal,crystal,deuterium').eq('planet_id', p.id).maybeSingle()
    if (!res) continue
    if (Number(res.metal) < 48 || Number(res.crystal) < 24) {
      const { data: info } = await sb.rpc('can_start_building', { p_player_id: p.player_id, p_planet_id: p.id, p_building_id: 'metal_mine' })
      const row = info?.[0]
      if (row && row.allowed === false) { lowCase = { p, row }; break }
    }
  }
  if (lowCase) check('recursos insuficientes -> allowed=false con motivo', /recurso/i.test(String(lowCase.row.reason)), `${lowCase.p.name}: "${lowCase.row.reason}"`)
  else skip('recursos insuficientes', 'no hay planeta visible con recursos por debajo del coste')

  // 6) invariantes de datos
  const { data: active } = await sb.from('building_queue').select('planet_id,status').in('status', ['BUILDING', 'QUEUED', 'ACTIVE'])
  const perPlanet = new Map()
  for (const r of active ?? []) perPlanet.set(r.planet_id, (perPlanet.get(r.planet_id) ?? 0) + 1)
  const duplicated = [...perPlanet.entries()].filter(([, n]) => n > 1)
  check('invariante: como maximo una construccion activa por planeta', duplicated.length === 0, `${active?.length ?? 0} activas en ${perPlanet.size} planetas`)

  const { data: doneQueue } = await sb.from('building_queue').select('planet_id,building_id,target_level,status').eq('status', 'COMPLETED').limit(200)
  const { data: levels } = await sb.from('planet_buildings').select('planet_id,building_id,level').limit(500)
  const levelOf = new Map((levels ?? []).map(l => [`${l.planet_id}:${l.building_id}`, l.level]))
  const notPersisted = (doneQueue ?? []).filter(q => (levelOf.get(`${q.planet_id}:${q.building_id}`) ?? 0) < Number(q.target_level))
  check('invariante: toda cola COMPLETED tiene su nivel persistido en planet_buildings', notPersisted.length === 0, `${doneQueue?.length ?? 0} completadas revisadas`)
}

// 7) motor de produccion y helpers de proyeccion
if (planet?.id) {
  const engine = await sb.rpc('calculate_planet_production', { p_planet_id: planet.id })
  if (engine.error) skip('calculate_planet_production (motor autoritativo)', `no invocable con estas credenciales: ${engine.error.message}`)
  else check('calculate_planet_production responde y no es negativo', Number(engine.data?.[0]?.metal_per_hour) >= 0, JSON.stringify(engine.data?.[0]))

  const proj = await sb.rpc('project_building_production', { p_planet_id: planet.id, p_building_id: 'metal_mine' })
  console.log(`      helper project_building_production -> ${proj.error ? 'ERROR: ' + proj.error.message : JSON.stringify(proj.data?.[0])}`)
  const delta = await sb.rpc('calculate_building_production_delta', { p_planet_id: planet.id, p_building_id: 'metal_mine' })
  console.log(`      helper calculate_building_production_delta -> ${delta.error ? 'ERROR: ' + delta.error.message : JSON.stringify(delta.data?.[0])}`)
  console.log('      (ambos helpers estan SIN USO por el motor y la UI; ver docs/systems/README_GAME_ENGINE_AUDIT.md)')
}

console.log(`\n== resultado: ${fails === 0 ? 'PASS' : `${fails} FAIL`} ==\n`)
process.exit(fails === 0 ? 0 : 1)
