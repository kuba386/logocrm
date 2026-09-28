'use client'

import { useEffect, useRef, useState } from 'react'

type TurnstileApi = {
  render: (
    container: HTMLElement,
    options: {
      sitekey: string
      language?: string
      callback?: (token: string) => void
      'expired-callback'?: () => void
      'error-callback'?: () => void
    },
  ) => string
  reset: (widgetId: string) => void
  remove: (widgetId: string) => void
}

declare global {
  interface Window {
    turnstile?: TurnstileApi
  }
}

const SCRIPT_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'
let scriptPromise: Promise<void> | null = null

function loadScript(): Promise<void> {
  if (window.turnstile) return Promise.resolve()
  scriptPromise ??= new Promise<void>((resolve, reject) => {
    const script = document.createElement('script')
    script.src = SCRIPT_SRC
    script.async = true
    script.onload = () => resolve()
    script.onerror = () => {
      scriptPromise = null
      reject(new Error('Не загрузился скрипт капчи'))
    }
    document.head.appendChild(script)
  })
  return scriptPromise
}

/**
 * Капча Cloudflare Turnstile для форм входа и регистрации. Токен кладётся в
 * скрытое поле `captcha_token`, сервер-экшен отдаёт его Supabase Auth как
 * `captchaToken`. Ключ сайта не задан (staging, локально, e2e) — компонент
 * ничего не рисует, формы работают как раньше. Токен одноразовый: после
 * каждой отправки виджет сбрасывается и выдаёт новый — иначе повторная
 * попытка после опечатки в пароле уходила бы с уже погашенным токеном.
 */
export function TurnstileField() {
  const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY
  const box = useRef<HTMLDivElement>(null)
  const [token, setToken] = useState('')

  useEffect(() => {
    const container = box.current
    if (!siteKey || !container) return

    let widgetId: string | undefined
    let cancelled = false
    const form = container.closest('form')

    // setTimeout: FormData формы собирается синхронно в том же событии, а
    // сброс должен идти после — иначе токен обнулился бы до отправки.
    const onSubmit = () =>
      setTimeout(() => {
        setToken('')
        if (widgetId && window.turnstile) window.turnstile.reset(widgetId)
      }, 0)

    loadScript()
      .then(() => {
        if (cancelled || !window.turnstile) return
        widgetId = window.turnstile.render(container, {
          sitekey: siteKey,
          language: 'ru',
          callback: setToken,
          'expired-callback': () => setToken(''),
          'error-callback': () => setToken(''),
        })
      })
      .catch(() => undefined)

    form?.addEventListener('submit', onSubmit)
    return () => {
      cancelled = true
      form?.removeEventListener('submit', onSubmit)
      if (widgetId && window.turnstile) window.turnstile.remove(widgetId)
    }
  }, [siteKey])

  if (!siteKey) return null

  return (
    <>
      <div ref={box} />
      <input type="hidden" name="captcha_token" value={token} />
    </>
  )
}
