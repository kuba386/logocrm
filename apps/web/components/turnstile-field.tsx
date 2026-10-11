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
 *
 * Пока нового токена нет (первые 1–3 секунды и после каждой отправки), форма
 * не уходит: поле токена — `required`, браузер сам останавливает отправку и
 * просит подождать. Раньше быстрый повтор уходил с пустым токеном и получал
 * от Supabase «captcha protection: no captcha_token found» — на prod 7.10
 * таких отказов было ~20 подряд на входе и регистрации.
 */
export function TurnstileField() {
  const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY
  const box = useRef<HTMLDivElement>(null)
  const [token, setToken] = useState('')
  // Проверка не загрузилась (блокировщик рекламы, сеть) — говорим сразу, а не
  // после отправки невнятным отказом сервера (UX-аудит, правило UX33).
  const [failed, setFailed] = useState(false)
  const tokenInput = useRef<HTMLInputElement>(null)

  // Своё сообщение вместо «Заполните это поле»: поле невидимое, человеку нужно
  // понять, чего ждать.
  useEffect(() => {
    tokenInput.current?.setCustomValidity(token ? '' : 'Подождите секунду — идёт проверка «я не робот»')
  }, [token])

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
          callback: (value: string) => {
            setFailed(false)
            setToken(value)
          },
          'expired-callback': () => setToken(''),
          'error-callback': () => {
            setToken('')
            setFailed(true)
          },
        })
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })

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
      {/* min-h — место под виджет заранее: без него он сдвигал кнопку при загрузке. */}
      <div className="relative">
        <div ref={box} className="min-h-[65px]" />
        {/* Не hidden: скрытые поля не проверяются браузером, а нам нужен required.
            Невидимое и вне Tab-порядка, но подсказка браузера встанет под виджетом. */}
        <input
          ref={tokenInput}
          name="captcha_token"
          value={token}
          onChange={() => {}}
          required
          tabIndex={-1}
          aria-hidden="true"
          autoComplete="off"
          className="pointer-events-none absolute bottom-0 left-1/2 h-px w-px opacity-0"
        />
      </div>
      {!token && !failed ? (
        <p className="text-xs text-muted-foreground" aria-live="polite">
          Проверяем, что вы не робот…
        </p>
      ) : null}
      {failed ? (
        <p role="alert" className="text-sm text-destructive">
          Не загрузилась проверка «я не робот». Обновите страницу; если не помогло — отключите блокировщик рекламы для этого сайта.
        </p>
      ) : null}
    </>
  )
}
