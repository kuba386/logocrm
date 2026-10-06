'use client'

import { useState } from 'react'
import { Button } from '@/components/ui/button'

/**
 * Копирует строку в буфер. «Скопировано» на 2 секунды; без доступа к буферу
 * (не https, запрет браузера) — честное «Не удалось», а не тишина.
 */
export function CopyButton({ text, label = 'Скопировать' }: { text: string; label?: string }) {
  const [status, setStatus] = useState<'idle' | 'copied' | 'failed'>('idle')

  return (
    <Button
      type="button"
      variant="outline"
      size="sm"
      aria-live="polite"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text)
          setStatus('copied')
        } catch {
          setStatus('failed')
        }
        setTimeout(() => setStatus('idle'), 2000)
      }}
    >
      {status === 'copied' ? 'Скопировано' : status === 'failed' ? 'Не удалось скопировать' : label}
    </Button>
  )
}
