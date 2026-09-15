interface Env {
  ASSETS: Fetcher
  IP_HASH_SALT?: string
  DEV_IP_HASH?: string
}

function bytesToHex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

async function hashVisitorIp(ip: string, salt: string) {
  const payload = new TextEncoder().encode(`${salt}:${ip}`)
  return bytesToHex(await crypto.subtle.digest('SHA-256', payload))
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    if (url.pathname === '/api/visitor') {
      const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown'
      const country = (request.cf?.country ?? request.headers.get('CF-IPCountry') ?? 'XX').toUpperCase()
      const ipHash = await hashVisitorIp(ip, env.IP_HASH_SALT ?? '')
      const isDeveloper = Boolean(env.DEV_IP_HASH && ipHash === env.DEV_IP_HASH)

      return Response.json(
        { country, ipHash, isDeveloper },
        {
          headers: {
            'Cache-Control': 'no-store',
          },
        },
      )
    }

    if (url.pathname.startsWith('/api/')) {
      return Response.json({ name: 'Cloudflare' })
    }

    return env.ASSETS.fetch(request)
  },
} satisfies ExportedHandler<Env>
