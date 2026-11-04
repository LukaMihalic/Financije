// Financije – service worker: omogućuje instalaciju kao aplikacije.
// Stranicu uvijek dohvaća svježu s interneta (ne sprema staru verziju).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method === 'GET' && r.mode === 'navigate') {
    e.respondWith(fetch(r, { cache: 'no-store' }).catch(() => fetch(r)));
  }
});
