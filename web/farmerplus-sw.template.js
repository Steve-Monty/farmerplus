const CACHE = 'farmerplus-__BUILD_HASH__';
const PRECACHE = __PRECACHE__;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(PRECACHE)));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith('farmerplus-') && key !== CACHE)
      .map(key => caches.delete(key))
  )).then(() => self.clients.claim()));
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === 'navigate') {
    const shellRoutes = ['/', '/auth/verify', '/auth/reset', '/auth/callback'];
    if (shellRoutes.includes(url.pathname)) {
      event.respondWith(fetch(request).catch(() => caches.match('/index.html')));
    }
    return;
  }
  if (PRECACHE.includes(url.pathname)) {
    event.respondWith(caches.match(request).then(cached => cached || fetch(request)));
  }
});
