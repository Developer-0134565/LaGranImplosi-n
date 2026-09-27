import { createReadStream, statSync } from 'node:fs'
import { createServer } from 'node:http'
import { extname, join, normalize, resolve } from 'node:path'

const args = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}

const root = resolve(arg('root', join(process.cwd(), 'dist', 'client')))
const port = Number(arg('port', 0))

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
}

const server = createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url ?? '/', 'http://127.0.0.1').pathname)
  const relative = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '')
  const file = normalize(join(root, relative))

  if (file !== root && !file.startsWith(root + '\\') && !file.startsWith(root + '/')) {
    response.writeHead(403)
    response.end('Forbidden')
    return
  }

  let target = file
  try {
    if (!statSync(target).isFile()) target = join(root, 'index.html')
  } catch {
    target = join(root, 'index.html')
  }

  const type = mime[extname(target).toLowerCase()] ?? 'application/octet-stream'
  response.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' })
  createReadStream(target).on('error', () => response.destroy()).pipe(response)
})

server.on('error', (error) => {
  console.error(error)
  process.exitCode = 1
})

server.listen(port, '127.0.0.1', () => {
  const address = server.address()
  console.log(`READY ${typeof address === 'object' && address ? address.port : port}`)
})
