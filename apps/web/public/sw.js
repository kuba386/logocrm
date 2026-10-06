/*
 * Service worker LogoCRM — только страница «Нет связи».
 *
 * Данные центра (ученики, диагностики, деньги) на телефоне не кэшируются
 * намеренно: устройство теряют и передают, а это данные детей. Поэтому
 * перехватываются только переходы между страницами — и то лишь чтобы при
 * обрыве сети показать /offline.html вместо ошибки браузера. Запросы данных,
 * серверные действия и статика идут в сеть как без service worker.
 */
const CACHE = 'logocrm-offline-v1'
const OFFLINE_URL = '/offline.html'

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll([OFFLINE_URL, '/icons/icon-192.png'])).then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate') return
  event.respondWith(fetch(event.request).catch(() => caches.match(OFFLINE_URL)))
})
