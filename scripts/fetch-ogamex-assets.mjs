import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const TARGET_ROOT = join(ROOT, 'public', 'assets', 'ogamex', 'objects')
const SOURCE_COMMIT = '7c420bad3478d7099791e1f33c920e9ff92822e8'
/* Manifest paths are a CROSS-PLATFORM contract: the file is committed and consumed on Linux, macOS
   and Windows, so the separator must be POSIX on every host. `path.relative` returns the NATIVE
   separator, and the previous `.replaceAll('\\\\', '/')` searched for a DOUBLE backslash (the JS
   literal `'\\\\'` is two characters), so it never matched and every Windows build rewrote all 124
   committed entries as "buildings\\x.jpg", dirtying the tree on each `npm run build` (`prebuild`
   runs this script). Splitting on the real `sep` is correct on both platforms and needs no escaping. */
const toPosix = (p) => p.split(sep).join('/')
const API_ROOT = `https://api.github.com/repos/lanedirt/OGameX/git/trees/${SOURCE_COMMIT}?recursive=1`
const RAW_ROOT = `https://raw.githubusercontent.com/lanedirt/OGameX/${SOURCE_COMMIT}/`
const MANIFEST = join(TARGET_ROOT, 'manifest.json')

const response = await fetch(API_ROOT)
if (!response.ok) throw new Error(`No se pudo consultar OGameX: HTTP ${response.status}`)
const tree = await response.json()

const sourceFiles = tree.tree
  .filter((entry) =>
    entry.type === 'blob' &&
    /^public\/img\/objects\/(buildings|research|units)\/.*_(micro|small)\.(png|jpg)$/i.test(entry.path),
  )
  .filter((entry, index, all) => all.findIndex((candidate) => candidate.path === entry.path) === index)

await mkdir(TARGET_ROOT, { recursive: true })

let downloaded = 0
let skipped = 0
const manifest = {
  source: 'lanedirt/OGameX',
  sourceCommit: SOURCE_COMMIT,
  sourceRoot: 'public/img/objects',
  targetRoot: 'public/assets/ogamex/objects',
  intendedUse: 'Referencia visual local para el prototipo de interfaz de La Gran Implosión.',
  license: 'OGameX source code is MIT; OGameX states that OGame artwork/rights belong to GameForge GmbH. These files are reference-only and must be replaced or relicensed before public/commercial distribution.',
  files: [],
}

for (const entry of sourceFiles) {
  const relativeSource = entry.path.replace(/^public\/img\/objects\//, '')
  const target = join(TARGET_ROOT, relativeSource)
  await mkdir(dirname(target), { recursive: true })

  try {
    const stat = await readFile(target)
    if (stat.length === Number(entry.size)) {
      skipped += 1
      manifest.files.push({ source: entry.path, target: toPosix(relative(TARGET_ROOT, target)), size: stat.length })
      continue
    }
  } catch {}

  const rawUrl = RAW_ROOT + entry.path
  const asset = await fetch(rawUrl)
  if (!asset.ok) throw new Error(`No se pudo descargar ${entry.path}: HTTP ${asset.status}`)
  const bytes = Buffer.from(await asset.arrayBuffer())
  await writeFile(target, bytes)
  downloaded += 1
  manifest.files.push({ source: entry.path, target: toPosix(relative(TARGET_ROOT, target)), size: bytes.length })
}

await writeFile(MANIFEST, JSON.stringify(manifest, null, 2) + '\n')
console.log(`OGameX assets: ${downloaded} descargados, ${skipped} ya existentes, ${sourceFiles.length} previstos.`)
