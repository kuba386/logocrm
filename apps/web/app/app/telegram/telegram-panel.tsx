'use client'

import { useState, useTransition } from 'react'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { issueLinkCode, unlinkTelegram, type TelegramState } from './actions'

/**
 * Код показывается один раз и живёт 15 минут. Ссылка t.me собирается здесь,
 * а не в базе: имя бота — настройка окружения, а не данные центра.
 */
export function TelegramPanel({ linked, botName }: { linked: boolean; botName: string | null }) {
  const [state, setState] = useState<TelegramState>({})
  const [pending, startTransition] = useTransition()

  const run = (action: () => Promise<TelegramState>) =>
    startTransition(async () => setState(await action()))

  return (
    <div className="space-y-3">
      <FormError message={state.message} />
      <FormNotice message={state.notice} />

      {linked ? (
        <Button variant="outline" disabled={pending} onClick={() => run(unlinkTelegram)}>
          {t('integrations', 'unlink')}
        </Button>
      ) : (
        <>
          <p className="text-sm text-muted-foreground">{t('integrations', 'linkHint')}</p>
          <Button disabled={pending} onClick={() => run(issueLinkCode)}>
            {t('integrations', 'getCode')}
          </Button>
        </>
      )}

      {state.code ? (
        <div className="space-y-2 rounded-md border border-border bg-muted/40 p-3">
          <p className="font-mono text-sm break-all">{t('integrations', 'codeReady', { code: state.code })}</p>
          {botName ? (
            <a
              href={`https://t.me/${botName}?start=${state.code}`}
              target="_blank"
              rel="noreferrer"
              className="text-sm font-medium text-primary hover:underline"
            >
              {t('integrations', 'openBot')}
            </a>
          ) : (
            <p className="text-xs text-muted-foreground">{t('integrations', 'botMissing')}</p>
          )}
        </div>
      ) : null}
    </div>
  )
}
