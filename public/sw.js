const CACHE = 'couple-life-v2'
self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE)
    const response = await fetch('/')
    await cache.put('/', response.clone())
    const html = await response.text()
    const assets = [...html.matchAll(/(?:src|href)="([^"]+\.(?:js|css))"/g)].map(match => match[1])
    await Promise.all(assets.map(async asset => { try { const file = await fetch(asset); if (file.ok) await cache.put(asset, file) } catch { /* an asset may be unavailable during a deploy */ } }))
    await cache.add('/manifest.webmanifest')
    await Promise.all(['/app-icon-192.png','/app-icon-512.png','/app-icon.svg'].map(async asset => { try { await cache.add(asset) } catch { /* icons may be unavailable during a deploy */ } }))
    self.skipWaiting()
  })())
})
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const key of await caches.keys()) if (key.startsWith('couple-life-') && key !== CACHE) await caches.delete(key)
  await self.clients.claim()
})()))
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url)
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search) return
  if (event.request.mode === 'navigate' || url.pathname === '/') {
    event.respondWith((async () => {
      try {
        const response = await fetch(event.request)
        if (response.ok) { const cache = await caches.open(CACHE); await cache.put('/', response.clone()) }
        return response
      } catch { return (await caches.match('/')) || Response.error() }
    })())
    return
  }
  event.respondWith((async () => {
    const cached = await caches.match(event.request)
    if (cached) return cached
    try {
      const response = await fetch(event.request)
      if (response.ok) { const cache = await caches.open(CACHE); await cache.put(event.request, response.clone()) }
      return response
    }
    catch { return (await caches.match('/')) || Response.error() }
  })())
})
