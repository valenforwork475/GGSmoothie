const CACHE_NAME = 'gg-pos-shell-v5';
const APP_SHELL = [
  '/POS-1c-standalone.html',
  '/manifest.webmanifest',
  '/assets/pos-app-icon.svg',
  '/assets/pos-app-icon-192.png',
  '/assets/pos-app-icon-512.png',
  '/assets/gg-pos-logo.png',
  '/assets/transaction-success-v1.webp',
  '/offline.html'
];

self.addEventListener('install', event => {
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (event.request.mode === 'navigate' || url.pathname.endsWith('.html')) {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(async () => (await caches.match('/POS-1c-standalone.html')) || caches.match('/offline.html'))
    );
    return;
  }

  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});
