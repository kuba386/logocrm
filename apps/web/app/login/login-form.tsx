'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { sendMagicLink, sendPasswordReset, signIn, signUp, type AuthState } from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { TurnstileField } from '@/components/turnstile-field'

const initialState: AuthState = {}

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? 'Подождите…' : children}
    </Button>
  )
}

export function LoginForm({ next }: { next: string }) {
  const [mode, setMode] = useState<'password' | 'magic' | 'reset'>('password')
  const [passwordState, passwordAction] = useActionState(signIn, initialState)
  const [signUpState, signUpAction] = useActionState(signUp, initialState)
  const [magicState, magicAction] = useActionState(sendMagicLink, initialState)
  const [resetState, resetAction] = useActionState(sendPasswordReset, initialState)

  if (mode === 'reset') {
    return (
      <form action={resetAction} className="space-y-4">
        <p className="text-sm text-muted-foreground">
          Пришлём письмо со ссылкой — по ней вы зададите новый пароль.
        </p>
        <div className="space-y-2">
          <Label htmlFor="reset-email">Email</Label>
          <Input id="reset-email" name="email" type="email" autoComplete="email" required />
        </div>

        <TurnstileField />

        <FormError message={resetState.error} />
        <FormNotice message={resetState.notice} />

        <SubmitButton>Отправить ссылку для смены пароля</SubmitButton>

        <Button type="button" variant="link" className="w-full" onClick={() => setMode('password')}>
          Вспомнил пароль — войти
        </Button>
      </form>
    )
  }

  if (mode === 'magic') {
    return (
      <form action={magicAction} className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="magic-email">Email</Label>
          <Input id="magic-email" name="email" type="email" autoComplete="email" required />
        </div>

        <TurnstileField />

        <FormError message={magicState.error} />
        <FormNotice message={magicState.notice} />

        <SubmitButton>Отправить ссылку для входа</SubmitButton>

        <Button type="button" variant="link" className="w-full" onClick={() => setMode('password')}>
          Войти по паролю
        </Button>
      </form>
    )
  }

  return (
    <form action={passwordAction} className="space-y-4">
      <input type="hidden" name="next" value={next} />

      <div className="space-y-2">
        <Label htmlFor="email">Email</Label>
        <Input id="email" name="email" type="email" autoComplete="email" required />
      </div>

      <div className="space-y-2">
        <div className="flex items-baseline justify-between gap-2">
          <Label htmlFor="password">Пароль</Label>
          <button
            type="button"
            className="text-xs text-primary hover:underline"
            onClick={() => setMode('reset')}
          >
            Забыли пароль?
          </button>
        </div>
        <Input id="password" name="password" type="password" autoComplete="current-password" required />
      </div>

      <TurnstileField />

      <FormError message={passwordState.error ?? signUpState.error} />
      <FormNotice message={signUpState.notice} />

      <div className="space-y-2">
        <SubmitButton>Войти</SubmitButton>
        <Button type="submit" variant="outline" className="w-full" formAction={signUpAction}>
          Зарегистрироваться
        </Button>
      </div>

      <Button type="button" variant="link" className="w-full" onClick={() => setMode('magic')}>
        Войти по ссылке из письма
      </Button>
    </form>
  )
}
