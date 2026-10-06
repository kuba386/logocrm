'use client'

import { useEffect } from 'react'

/**
 * Регистрирует /sw.js — он только показывает «Нет связи» при обрыве сети,
 * данные не кэширует (public/sw.js). Только в prod-сборке: в dev service
 * worker пережил бы перезапуск сервера и путал бы горячую перезагрузку.
 */
export function RegisterServiceWorker() {
  useEffect(() => {
    if (process.env.NODE_ENV !== 'production' || !('serviceWorker' in navigator)) return
    navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {
      // Без service worker всё работает, кроме офлайн-страницы, — не повод для ошибки.
    })
  }, [])
  return null
}
