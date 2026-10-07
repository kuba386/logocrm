'use client'

import { useState, useTransition } from 'react'
import { Button, buttonVariants } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { ConfirmAction } from '@/components/ui/confirm-submit'
import { t } from '@/lib/messages'
import { formatInTimeZone } from '@/lib/timezone'
import { createPayerTelegramLink, disconnectParent, type PayerTelegramState } from './telegram-actions'

export type PayerTelegramStatus = {
  link: { created_at: string; expires_at: string } | null
  parents: { user_id: string; name: string; via_bot: boolean; telegram: boolean; linked_at: string }[]
}

/**
 * Кто из родителей подключён к боту и личная ссылка для нового (0098).
 * Ссылку выдают только владелец и администратор (решение владельца, 0098 В2) —
 * база откажет остальным и так, кнопка просто не показывается.
 */
export function PayerTelegramPanel({
  payerId,
  whatsapp,
  status,
  canManage,
  timeZone,
}: {
  payerId: string
  whatsapp: string | null
  status: PayerTelegramStatus
  canManage: boolean
  timeZone: string
}) {
  const [state, setState] = useState<PayerTelegramState>({})
  const [copied, setCopied] = useState(false)
  const [pending, startTransition] = useTransition()

  const run = (action: () => Promise<PayerTelegramState>) =>
    startTransition(async () => {
      setCopied(false)
      setState(await action())
    })

  const when = (iso: string) =>
    formatInTimeZone(iso, timeZone, { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' })

  const link = state.link
  const whatsappHref =
    link && whatsapp
      ? `https://wa.me/${whatsapp}?text=${encodeURIComponent(t('payerTelegram', 'whatsappText', { url: link.url }))}`
      : null

  return (
    <div className="space-y-4">
      <FormError message={state.message} />
      <FormNotice message={state.notice} />

      {status.parents.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('payerTelegram', 'none')}</p>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border">
          {status.parents.map((parent) => (
            <li key={parent.user_id} className="flex flex-wrap items-center justify-between gap-2 p-3">
              <div className="min-w-0">
                <p className="truncate font-medium">{parent.name}</p>
                <p className="text-xs text-muted-foreground">
                  {[
                    t('payerTelegram', parent.via_bot ? 'viaBot' : 'viaWeb'),
                    parent.telegram ? null : t('payerTelegram', 'noTelegram'),
                    t('payerTelegram', 'since', { date: when(parent.linked_at) }),
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </div>
              {canManage ? (
                <ConfirmAction
                  variant="outline"
                  pending={pending}
                  label={t('payerTelegram', 'disconnect')}
                  question={t('payerTelegram', 'disconnectConfirm', { name: parent.name })}
                  onConfirm={() => run(() => disconnectParent(payerId, parent.user_id))}
                />
              ) : null}
            </li>
          ))}
        </ul>
      )}

      {status.link && !link ? (
        <p className="text-sm text-muted-foreground">
          {t('payerTelegram', 'liveLink', { date: when(status.link.expires_at) })}
        </p>
      ) : null}

      {canManage ? (
        <Button variant={status.parents.length > 0 || status.link ? 'outline' : 'default'} disabled={pending} onClick={() => run(() => createPayerTelegramLink(payerId))}>
          {t('payerTelegram', status.parents.length > 0 || status.link ? 'createAgain' : 'create')}
        </Button>
      ) : null}

      {link ? (
        <div className="space-y-3 rounded-md border border-border bg-muted/40 p-3">
          <p className="text-sm">{t('payerTelegram', 'linkReady', { date: when(link.expiresAt) })}</p>
          <p className="font-mono text-sm break-all">{link.url}</p>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(link.url)
                  setCopied(true)
                } catch {
                  setCopied(false)
                }
              }}
            >
              {copied ? t('payerTelegram', 'copied') : t('payerTelegram', 'copy')}
            </Button>
            {whatsappHref ? (
              <a href={whatsappHref} target="_blank" rel="noreferrer" className={buttonVariants({ size: 'sm' })}>
                {t('payerTelegram', 'sendWhatsapp')}
              </a>
            ) : null}
          </div>
          {/* SVG собран на сервере библиотекой qrcode из ссылки — не пользовательский ввод;
              data:-URI next/image не оптимизирует. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={`data:image/svg+xml;utf8,${encodeURIComponent(link.qrSvg)}`}
            alt={t('payerTelegram', 'qrAlt')}
            width={160}
            height={160}
            className="rounded-md bg-white p-2"
          />
        </div>
      ) : null}
    </div>
  )
}
