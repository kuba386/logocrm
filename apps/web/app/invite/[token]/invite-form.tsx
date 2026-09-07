'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import {
  magicLinkAndAccept,
  signInAndAccept,
  signUpAndAccept,
  type InviteState,
} from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'

const initialState: InviteState = {}

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? 'Подождите…' : children}
    </Button>
  )
}

export function InviteForm({ token }: { token: string }) {
  const [mode, setMode] = useState<'signup' | 'signin' | 'magic'>('signup')
  const [signUpState, signUpAction] = useActionState(signUpAndAccept, initialState)
  const [signInState, signInAction] = useActionState(signInAndAccept, initialState)
  const [magicState, magicAction] = useActionState(magicLinkAndAccept, initialState)

  if (mode === 'magic') {
    return (
      <form action={magicAction} className="space-y-4">
        <input type="hidden" name="token" value={token} />

        <div className="space-y-2">
          <Label htmlFor="magic-email">Email</Label>
          <Input id="magic-email" name="email" type="email" autoComplete="email" required />
        </div>

        <FormError message={magicState.error} />
        <FormNotice message={magicState.notice} />

        <SubmitButton>Получить ссылку для входа</SubmitButton>

        <Button type="button" variant="link" className="w-full" onClick={() => setMode('signup')}>
          Назад
        </Button>
      </form>
    )
  }

  const isSignUp = mode === 'signup'
  const state = isSignUp ? signUpState : signInState

  return (
    <form action={isSignUp ? signUpAction : signInAction} className="space-y-4">
      <input type="hidden" name="token" value={token} />

      <div className="space-y-2">
        <Label htmlFor="email">Email</Label>
        <Input id="email" name="email" type="email" autoComplete="email" required />
      </div>

      <div className="space-y-2">
        <Label htmlFor="password">Пароль</Label>
        <Input
          id="password"
          name="password"
          type="password"
          autoComplete={isSignUp ? 'new-password' : 'current-password'}
          required
          minLength={6}
        />
      </div>

      <FormError message={state.error} />
      <FormNotice message={signUpState.notice} />

      <SubmitButton>{isSignUp ? 'Зарегистрироваться и войти' : 'Войти'}</SubmitButton>

      <div className="space-y-1 text-center">
        <Button
          type="button"
          variant="link"
          className="w-full"
          onClick={() => setMode(isSignUp ? 'signin' : 'signup')}
        >
          {isSignUp ? 'У меня уже есть аккаунт' : 'Я здесь впервые'}
        </Button>
        <Button type="button" variant="link" className="w-full" onClick={() => setMode('magic')}>
          Войти по ссылке из письма
        </Button>
      </div>
    </form>
  )
}
