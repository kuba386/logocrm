'use client'

import { useActionState, useState } from 'react'
import { cancelInvitation, type StaffState } from './actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { FormError } from '@/components/ui/alert'
import { roleLabel } from '@/lib/roles'

const initialState: StaffState = {}

export type PendingInvitation = {
  id: string
  role: string
  fullName: string | null
  /** Карточка плательщика у приглашения родителя (0060). */
  payerName: string | null
  phone: string | null
  email: string | null
  url: string
  expiresAt: string
}

function CopyButton({ url }: { url: string }) {
  const [copied, setCopied] = useState(false)

  return (
    <Button
      variant="outline"
      size="sm"
      onClick={async () => {
        await navigator.clipboard.writeText(url)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      }}
    >
      {copied ? 'Скопировано' : 'Скопировать ссылку'}
    </Button>
  )
}

function CancelButton({ invitationId }: { invitationId: string }) {
  const [state, formAction] = useActionState(cancelInvitation, initialState)

  return (
    <form action={formAction} className="inline">
      <input type="hidden" name="invitationId" value={invitationId} />
      <Button type="submit" variant="ghost" size="sm">
        Отменить
      </Button>
      <FormError message={state.error} />
    </form>
  )
}

function whatsappHref(invitation: PendingInvitation): string {
  const text = `Здравствуйте! Приглашаю вас в LogoCRM как ${roleLabel(invitation.role).toLowerCase()}. Ссылка для входа: ${invitation.url}`
  const phone = invitation.phone?.replace(/[^0-9]/g, '')
  return phone
    ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
    : `https://wa.me/?text=${encodeURIComponent(text)}`
}

export function PendingInvitations({ invitations }: { invitations: PendingInvitation[] }) {
  if (invitations.length === 0) {
    return <p className="text-sm text-muted-foreground">Нет активных приглашений.</p>
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>ФИО</TableHead>
          <TableHead>Роль</TableHead>
          <TableHead>Контакт</TableHead>
          <TableHead>Действует до</TableHead>
          <TableHead className="text-right">Действия</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {invitations.map((invitation) => (
          <TableRow key={invitation.id}>
            <TableCell className="font-medium">{invitation.fullName ?? invitation.payerName ?? '—'}</TableCell>
            <TableCell>{roleLabel(invitation.role)}</TableCell>
            <TableCell className="text-muted-foreground">
              {invitation.phone ?? invitation.email ?? '—'}
            </TableCell>
            <TableCell className="text-muted-foreground">
              {new Date(invitation.expiresAt).toLocaleDateString('ru-RU')}
            </TableCell>
            <TableCell>
              <div className="flex flex-wrap items-center justify-end gap-2">
                <CopyButton url={invitation.url} />
                <a
                  className={buttonVariants({ variant: 'outline', size: 'sm' })}
                  href={whatsappHref(invitation)}
                  target="_blank"
                  rel="noreferrer"
                >
                  В WhatsApp
                </a>
                <CancelButton invitationId={invitation.id} />
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}
