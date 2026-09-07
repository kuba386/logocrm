'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { sendMagicLink, signIn, signUp, type AuthState } from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'

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
  const [mode, setMode] = useState<'password' | 'magic'>('password')
  const [passwordState, passwordAction] = useActionState(signIn, initialState)
  const [signUpState, signUpAction] = useActionState(signUp, initialState)
  const [magicState, magicAction] = useActionState(sendMagicLink, initialState)

  if (mode === 'magic') {
    return (
      <form action={magicAction} className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="magic-email">Email</Label>
          <Input id="magic-email" name="email" type="email" autoComplete="email" required />
        </div>

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
        <Label htmlFor="password">Пароль</Label>
        <Input id="password" name="password" type="password" autoComplete="current-password" required />
      </div>

      <FormError message={passwordState.error ?? signUpState.error} />

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
