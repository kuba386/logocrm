'use client'

import { useActionState, useMemo, useRef } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { previewTemplate, resetTemplate, saveTemplate, type TemplateState } from './actions'
import { ConfirmSubmit } from '@/components/ui/confirm-submit'
import { useKeepValuesOnError } from '@/lib/use-keep-values'

const initial: TemplateState = {}

/**
 * Одна форма на три действия: сохранить, предпросмотреть и вернуть текст
 * платформы. Разные формы не видели бы отредактированный текст — предпросмотр
 * показывал бы сохранённое, а не то, что набрали.
 */
function ActionButton({
  children,
  formAction,
  variant,
  intent,
}: {
  children: React.ReactNode
  formAction?: (formData: FormData) => void
  variant?: 'outline'
  /** Какое из действий формы нажато — от этого зависит, восстанавливать ли текст после ответа. */
  intent: 'save' | 'preview'
}) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" size="sm" variant={variant} formAction={formAction} disabled={pending} data-intent={intent}>
      {children}
    </Button>
  )
}

export function TemplateForm({
  eventType,
  channel,
  text: body,
  isActive,
  isOwn,
  placeholders,
  mandatory = false,
}: {
  eventType: string
  channel: string
  text: string
  isActive: boolean
  isOwn: boolean
  placeholders: string[]
  /** 0052: напоминание о сроке не выключается — тумблер погашен, база отбивает 42501. */
  mandatory?: boolean
}) {
  const [saveState, saveAction] = useActionState(saveTemplate, initial)
  const [previewState, previewAction] = useActionState(previewTemplate, initial)
  const [resetState, resetAction] = useActionState(resetTemplate, initial)

  // React 19 сбрасывает форму после любого из трёх действий. Предпросмотр
  // не меняет базу — после него набранный текст возвращаем всегда (раньше
  // правка пропадала, а превью показывало уже отредактированный текст).
  // Сохранение — только при отказе. «Вернуть текст платформы» — никогда:
  // поле должно показать текст платформы.
  const intent = useRef<string>('')
  const states = useMemo(() => [saveState, previewState, resetState], [saveState, previewState, resetState])
  const keep = useKeepValuesOnError(
    states,
    intent.current === 'preview' || (intent.current === 'save' && Boolean(saveState.message)),
    (event) => {
      intent.current = (event.nativeEvent as SubmitEvent).submitter?.getAttribute('data-intent') ?? ''
    },
  )

  return (
    <form action={saveAction} className="space-y-2" {...keep}>
      <input type="hidden" name="eventType" value={eventType} />
      <input type="hidden" name="channel" value={channel} />

      <div className="flex items-center justify-between gap-2">
        <span className="text-sm font-medium">
          {channel === 'telegram' ? t('notifications', 'channelTelegram') : t('notifications', 'channelWhatsapp')}
        </span>
        <span className="text-xs text-muted-foreground">
          {isOwn ? t('notifications', 'own') : t('notifications', 'default')}
        </span>
      </div>

      <textarea
        name="text"
        aria-label={t('notifications', 'textLabel', {
          channel: channel === 'telegram' ? t('notifications', 'channelTelegram') : t('notifications', 'channelWhatsapp'),
        })}
        defaultValue={body}
        rows={3}
        className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
      />

      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          name="isActive"
          defaultChecked={mandatory || isActive}
          disabled={mandatory}
          className="h-4 w-4"
        />
        {t('notifications', 'active')}
        {mandatory ? (
          <span className="text-xs text-muted-foreground">{t('notifications', 'mandatoryHint')}</span>
        ) : null}
      </label>
      {mandatory ? <input type="hidden" name="isActive" value="on" /> : null}

      <p className="text-xs text-muted-foreground">
        {placeholders.length > 0
          ? t('notifications', 'placeholders', { list: placeholders.join(', ') })
          : t('notifications', 'noPlaceholders')}
      </p>

      <div className="flex flex-wrap gap-2">
        <ActionButton intent="save">{t('notifications', 'save')}</ActionButton>
        <ActionButton intent="preview" formAction={previewAction} variant="outline">
          {t('notifications', 'preview')}
        </ActionButton>
        {isOwn ? (
          <ConfirmSubmit
            formAction={resetAction}
            label={t('notifications', 'reset')}
            question={t('notifications', 'resetConfirm')}
          />
        ) : null}
      </div>

      <FormError message={saveState.message ?? previewState.message ?? resetState.message} />
      <FormNotice message={saveState.notice ?? resetState.notice} />

      {previewState.preview ? (
        <div className="rounded-md border border-border bg-muted/40 p-3 text-sm">
          <p className="whitespace-pre-line">{previewState.preview}</p>
          <p className="mt-1 text-xs text-muted-foreground">{t('notifications', 'previewHint')}</p>
        </div>
      ) : null}
    </form>
  )
}
