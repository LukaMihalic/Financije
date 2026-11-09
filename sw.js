// Financije – service worker
// • omogućuje instalaciju kao aplikacije
// • stranicu uvijek dohvaća svježu s interneta, a kopiju čuva za otvaranje bez interneta
// • biblioteke s CDN-a (Supabase, QR čitač, Excel) čuva nakon prvog učitavanja
const CACHE = 'financije-v2';
const CDN = /^https:\/\/(cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com)\//;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const url = new URL(r.url);

  // stranica aplikacije: najprije internet, a bez interneta zadnja spremljena kopija
  if (r.mode === 'navigate') {
    e.respondWith((async () => {
      try {
        const res = await fetch(r, { cache: 'no-store' });
        if (res.ok) (await caches.open(CACHE)).put('app-shell', res.clone());
        return res;
      } catch (err) {
        return (await caches.match('app-shell')) || Response.error();
      }
    })());
    return;
  }

  // ikone i manifest s iste adrese, te biblioteke s CDN-a: spremljena kopija, osvježena u pozadini
  if ((url.origin === location.origin && /\.(png|json)$/.test(url.pathname)) || CDN.test(r.url)) {
    e.respondWith((async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(r);
      const net = fetch(r).then(res => { if (res && (res.ok || res.type === 'opaque')) cache.put(r, res.clone()); return res; }).catch(() => null);
      return hit || (await net) || Response.error();
    })());
  }
  // sve ostalo (Supabase, Claude) ide izravno na internet
});
