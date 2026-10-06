'use client'

import { useActionState, useEffect, useMemo, useState } from 'react'
import { useFormStatus } from 'react-dom'
import {
  acceptSignedIn,
  magicLinkAndAccept,
  resendInviteCode,
  signInAndAccept,
  signUpAndAccept,
  verifyCodeAndAccept,
  type InviteState,
} from './actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { FormError, FormNotice } from '@/components/ui/alert'
import { TurnstileField } from '@/components/turnstile-field'
import { EmailCodeStep } from '@/components/email-code-step'
import { signOut } from '@/app/login/actions'
import { useKeepValuesOnError } from '@/lib/use-keep-values'

const initialState: InviteState = {}

function SubmitButton({ children }: { children: React.ReactNode }) {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" className="w-full" disabled={pending}>
      {pending ? 'Подождите…' : children}
    </Button>
  )
}

/** Вошедший пользователь: одна кнопка «Принять», без повторного пароля. */
export function AcceptSignedInForm({ token }: { token: string }) {
  const [state, action] = useActionState(acceptSignedIn, initialState)
  return (
    <div className="space-y-3">
      <form action={action} className="space-y-3">
        <input type="hidden" name="token" value={token} />
        <SubmitButton>Принять приглашение</SubmitButton>
        <FormError message={state.error} />
      </form>
      <form action={signOut}>
        <Button type="submit" variant="link" className="w-full">
          Это не мой аккаунт — выйти
        </Button>
      </form>
    </div>
  )
}

export function InviteForm({ token }: { token: string }) {
  const [mode, setMode] = useState<'signup' | 'signin' | 'magic'>('signup')
  const [signUpState, signUpAction] = useActionState(signUpAndAccept, initialState)
  const [signInState, signInAction] = useActionState(signInAndAccept, initialState)
  const [magicState, magicAction] = useActionState(magicLinkAndAccept, initialState)
  const formStates = useMemo(() => [signUpState, signInState], [signUpState, signInState])
  const keepForm = useKeepValuesOnError(formStates, Boolean(signUpState.error ?? signInState.error))
  const keepMagic = useKeepValuesOnError(magicState, Boolean(magicState.error))
  const [codeStep, setCodeStep] = useState<{ email: string; purpose: 'signup' | 'magic' } | null>(null)

  useEffect(() => {
    if (signUpState.codeSentTo) setCodeStep({ email: signUpState.codeSentTo, purpose: 'signup' })
  }, [signUpState])
  useEffect(() => {
    if (magicState.codeSentTo) setCodeStep({ email: magicState.codeSentTo, purpose: 'magic' })
  }, [magicState])

  if (codeStep) {
    return (
      <EmailCodeStep
        email={codeStep.email}
        purpose={codeStep.purpose}
        hidden={{ token }}
        verifyAction={verifyCodeAndAccept}
        resendAction={resendInviteCode}
        onBack={() => setCodeStep(null)}
      />
    )
  }

  if (mode === 'magic') {
    return (
      <form action={magicAction} className="space-y-4" {...keepMagic}>
        <input type="hidden" name="token" value={token} />

        <div className="space-y-2">
          <Label htmlFor="magic-email">Email</Label>
          <Input id="magic-email" name="email" type="email" autoComplete="email" required />
        </div>

        <TurnstileField />

        <p className="text-sm text-muted-foreground">Пришлём код на почту — введёте его здесь, пароль не нужен.</p>

        <FormError message={magicState.error} />

        <SubmitButton>Получить код для входа</SubmitButton>

        <Button type="button" variant="link" className="w-full" onClick={() => setMode('signup')}>
          Назад
        </Button>
      </form>
    )
  }

  const isSignUp = mode === 'signup'
  const state = isSignUp ? signUpState : signInState

  return (
    <form action={isSignUp ? signUpAction : signInAction} className="space-y-4" {...keepForm}>
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

      <TurnstileField />

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
          Войти по коду из письма
        </Button>
      </div>
    </form>
  )
}
