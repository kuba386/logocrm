'use client'

import { useEffect, useState } from 'react'
import { Download } from 'lucide-react'
import { Button } from '@/components/ui/button'

/** Событие Chrome/Edge/Android: установку можно предложить своей кнопкой. */
type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

/**
 * «Установить приложение» в меню (PWA). Кнопка появляется, только когда браузер
 * сам готов установить (beforeinstallprompt), и пропадает в уже установленном
 * приложении. Safari на iPhone такого события не даёт — там одна строка, как
 * добавить на экран «Домой».
 */
export function InstallApp() {
  const [deferred, setDeferred] = useState<BeforeInstallPromptEvent | null>(null)
  const [iosHint, setIosHint] = useState(false)
  const [installed, setInstalled] = useState(false)

  useEffect(() => {
    const standalone =
      window.matchMedia('(display-mode: standalone)').matches ||
      (navigator as Navigator & { standalone?: boolean }).standalone === true
    if (standalone) {
      setInstalled(true)
      return
    }
    const ua = navigator.userAgent
    // Только Safari умеет «На экран „Домой“»; Chrome и Firefox на iOS — нет.
    setIosHint(/iPhone|iPad|iPod/.test(ua) && !/CriOS|FxiOS|EdgiOS/.test(ua))

    const onPrompt = (event: Event) => {
      event.preventDefault()
      setDeferred(event as BeforeInstallPromptEvent)
    }
    const onInstalled = () => {
      setInstalled(true)
      setDeferred(null)
    }
    window.addEventListener('beforeinstallprompt', onPrompt)
    window.addEventListener('appinstalled', onInstalled)
    return () => {
      window.removeEventListener('beforeinstallprompt', onPrompt)
      window.removeEventListener('appinstalled', onInstalled)
    }
  }, [])

  if (installed) return null

  if (deferred) {
    return (
      <Button
        type="button"
        variant="ghost"
        size="sm"
        className="justify-start gap-2"
        onClick={async () => {
          await deferred.prompt()
          await deferred.userChoice
          // Событие одноразовое: после ответа браузер пришлёт новое, если снова можно.
          setDeferred(null)
        }}
      >
        <Download className="size-4" aria-hidden="true" />
        Установить приложение
      </Button>
    )
  }

  if (iosHint) {
    return (
      <p className="px-1 text-xs text-muted-foreground">
        Как приложение: в Safari «Поделиться» → «На экран „Домой“».
      </p>
    )
  }

  return null
}
