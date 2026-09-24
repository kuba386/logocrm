'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { useFormStatus } from 'react-dom'
import { ASSISTANT_EXAMPLES } from '@logocrm/contracts'
import { Button, buttonVariants } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { FormError, FormNotice } from '@/components/ui/alert'
import { t } from '@/lib/messages'
import { askAssistant, type AssistantState } from './actions'

const initial: AssistantState = {}

function AskButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={pending}>
      {pending ? t('assistant', 'asking') : t('assistant', 'ask')}
    </Button>
  )
}

function QuotaLine({ quota }: { quota?: { used: number; limit: number } }) {
  if (!quota) return null
  return (
    <p className="text-xs text-muted-foreground">
      {quota.limit < 0
        ? t('assistant', 'quotaUnlimited', { used: quota.used })
        : t('assistant', 'quota', { used: quota.used, limit: quota.limit })}
    </p>
  )
}

export function AssistantForm({ quota }: { quota?: { used: number; limit: number } }) {
  const [state, action] = useActionState(askAssistant, initial)

  return (
    <div className="space-y-6">
      <form action={action} className="space-y-3">
        <div className="flex flex-wrap gap-2">
          <Input
            name="question"
            placeholder={t('assistant', 'placeholder')}
            defaultValue={state.question ?? ''}
            maxLength={300}
            required
            autoComplete="off"
            className="min-w-64 flex-1"
            aria-label={t('assistant', 'title')}
          />
          <AskButton />
        </div>
        <p className="text-xs text-muted-foreground">{t('assistant', 'privacy')}</p>
        <QuotaLine quota={state.quota ?? quota} />
        <FormError message={state.error} />
        {state.notice ? <FormNotice message={state.notice} /> : null}
      </form>

      {state.answer ? (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{state.answer.title}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {state.answer.rows.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('assistant', 'empty')}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    {state.answer.columns.map((c) => (
                      <TableHead key={c}>{c}</TableHead>
                    ))}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {state.answer.rows.map((row, i) => (
                    <TableRow key={i}>
                      {row.map((cell, j) => (
                        <TableCell key={j}>{cell}</TableCell>
                      ))}
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
            {state.answer.link ? (
              <Link href={state.answer.link.href} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                {state.answer.link.label}
              </Link>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      <div>
        <p className="mb-2 text-sm font-medium">{t('assistant', 'examples')}</p>
        <div className="flex flex-wrap gap-2">
          {ASSISTANT_EXAMPLES.map((example) => (
            <form key={example} action={action}>
              <input type="hidden" name="question" value={example} />
              <Button type="submit" variant="outline" size="sm">
                {example}
              </Button>
            </form>
          ))}
        </div>
      </div>
    </div>
  )
}
