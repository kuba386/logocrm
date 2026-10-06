import type { MetadataRoute } from 'next'

/**
 * Установка на телефон (PWA): иконка на экране, открывается сразу в /app,
 * без строки браузера. Цвета — фирменные (#0F7466 из app/icon.svg).
 * Ярлыки — долгое нажатие на иконку в Android: два самых частых экрана
 * специалиста и администратора.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: '/app',
    name: 'LogoCRM',
    short_name: 'LogoCRM',
    description: 'Расписание, ученики, посещения и абонементы логопедического центра',
    lang: 'ru',
    dir: 'ltr',
    start_url: '/app',
    scope: '/',
    display: 'standalone',
    orientation: 'portrait',
    background_color: '#F4F7FA',
    theme_color: '#0F7466',
    categories: ['business', 'medical', 'productivity'],
    icons: [
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icons/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
    shortcuts: [
      { name: 'Расписание', url: '/app/schedule', icons: [{ src: '/icons/icon-192.png', sizes: '192x192' }] },
      { name: 'Ученики', url: '/app/students', icons: [{ src: '/icons/icon-192.png', sizes: '192x192' }] },
    ],
  }
}
