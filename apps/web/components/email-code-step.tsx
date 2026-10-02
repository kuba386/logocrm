'use client'

import { useActionState } from 'react'
import { useFormStatus } from 'react-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { TurnstileField } from '@/components/turnstile-field'

type CodeState = { error?: string; notice?: string }
type CodeAction = (prev: CodeState, formData: FormData) => Promise<CodeState>

function SubmitButton({ children, variant }: { children: React.ReactNode; variant?: 'link' }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" variant={variant} className="w-full" disabled={pending}>
      {pending ? 'Подождите…' : children}
    </Button>
  )
}

/**
 * Шаг «Введите код из письма» — общий для регистрации центра, входа по почте
 * и приглашения. Код вводится здесь же, поэтому неважно, в каком браузере
 * открыто письмо (lib/email-code.ts). Скрытые поля (next, token) уходят в
 * действие проверки как есть.
 */
export function EmailCodeStep({
  email,
  purpose,
  hidden = {},
  verifyAction,
  resendAction,
  onBack,
}: {
  email: string
  purpose: 'signup' | 'magic'
  hidden?: Record<string, string>
  verifyAction: CodeAction
  resendAction: CodeAction
  onBack: () => void
}) {
  const [verifyState, verify] = useActionState(verifyAction, {})
  const [resendState, resend] = useActionState(resendAction, {})

  const hiddenFields = (
    <>
      <input type="hidden" name="email" value={email} />
      <input type="hidden" name="purpose" value={purpose} />
      {Object.entries(hidden).map(([name, value]) => (
        <input key={name} type="hidden" name={name} value={value} />
      ))}
    </>
  )

  return (
    <div className="space-y-4">
      <form action={verify} className="space-y-4">
        {hiddenFields}
        <p className="text-sm">
          Мы отправили письмо с кодом на <span className="font-medium">{email}</span>. Введите код — письмо
          можно открыть где угодно, хоть на другом телефоне.
        </p>
        <div className="space-y-2">
          <Label htmlFor="email-code">Код из письма</Label>
          <Input
            id="email-code"
            name="code"
            inputMode="numeric"
            autoComplete="one-time-code"
            autoFocus
            required
            maxLength={12}
            placeholder="123456"
            className="text-center font-display text-xl tracking-[0.35em]"
          />
        </div>
        <FormError message={verifyState.error} />
        <SubmitButton>{purpose === 'signup' ? 'Подтвердить почту' : 'Войти'}</SubmitButton>
      </form>

      <form action={resend} className="space-y-2 border-t border-border pt-4">
        {hiddenFields}
        <p className="text-xs text-muted-foreground">
          Письма нет 5 минут — проверьте «Спам». Запросили код ещё раз — вводите код из последнего письма.
        </p>
        <TurnstileField />
        <FormError message={resendState.error} />
        <FormNotice message={resendState.notice} />
        <SubmitButton variant="link">Отправить код ещё раз</SubmitButton>
      </form>

      <Button type="button" variant="link" className="w-full" onClick={onBack}>
        Указать другой email
      </Button>
    </div>
  )
}
