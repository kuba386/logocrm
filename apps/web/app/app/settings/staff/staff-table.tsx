'use client'

import { useActionState, useState } from 'react'
import { changeMemberRole, linkParentPayer, revokeMembership, type StaffState } from './actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Select } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { FormError, FormNotice } from '@/components/ui/alert'
import { assignableRoles, roleLabel } from '@/lib/roles'
import { VacationDialog } from './vacation-dialog'
import { PayerPicker, type PayerOption } from './invite-dialog'

const initialState: StaffState = {}

export type StaffMember = {
  userId: string
  email: string | null
  role: string
  fullName: string | null
  isActive: boolean
  joinedAt: string | null
  teacherId: string | null
  payerId: string | null
  payerName: string | null
}

/**
 * Привязка родителя к карточке плательщика (0060) — починка «ничьего»
 * родителя и исправление ошибочной привязки одним действием; «Отвязать» —
 * когда родитель видит чужого ребёнка.
 */
function LinkPayerDialog({ member, payers }: { member: StaffMember; payers: PayerOption[] }) {
  const [open, setOpen] = useState(false)
  const [payerId, setPayerId] = useState(member.payerId ?? '')
  const [state, formAction] = useActionState(linkParentPayer, initialState)
  const orphan = !member.payerId

  return (
    <>
      <Button variant={orphan ? 'default' : 'outline'} size="sm" onClick={() => setOpen(true)}>
        {orphan ? 'Привязать плательщика' : 'Сменить плательщика'}
      </Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title={orphan ? 'Привязать плательщика' : 'Сменить плательщика'}
        description={`${member.email ?? 'Родитель'} увидит детей выбранной карточки и перестанет видеть остальных.`}
      >
        {state.notice ? <FormNotice message={state.notice} /> : null}
        <form action={formAction} className="space-y-4">
          <input type="hidden" name="userId" value={member.userId} />
          <div className="space-y-2">
            <label htmlFor={`payer-${member.userId}`} className="text-sm font-medium">
              Карточка плательщика
            </label>
            <Select
              id={`payer-${member.userId}`}
              name="payerId"
              value={payerId}
              onChange={(e) => setPayerId(e.target.value)}
            >
              <option value="">Не привязан</option>
              {payers.map((payer) => (
                <option key={payer.id} value={payer.id}>
                  {payer.fullName}
                  {payer.phone ? ` · ${payer.phone}` : ''}
                  {payer.children.length ? ` · дети: ${payer.children.join(', ')}` : ' · детей нет'}
                </option>
              ))}
            </Select>
          </div>
          <FormError message={state.error} />
          <div className="flex gap-2">
            <Button type="submit">{payerId ? 'Привязать' : 'Отвязать'}</Button>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Закрыть
            </Button>
          </div>
        </form>
      </Dialog>
    </>
  )
}

function RoleSelect({ member, actorRole }: { member: StaffMember; actorRole: string }) {
  const [state, formAction] = useActionState(changeMemberRole, initialState)

  // Администратор не трогает владельцев и других администраторов —
  // то же правило стоит в change_member_role.
  const locked = actorRole === 'admin' && (member.role === 'owner' || member.role === 'admin')

  if (locked) {
    return <span className="text-sm">{roleLabel(member.role)}</span>
  }

  const options = assignableRoles(actorRole)
  const known = options.some((option) => option.value === member.role)

  return (
    <form action={formAction} className="space-y-1">
      <input type="hidden" name="userId" value={member.userId} />
      <Select
        name="role"
        defaultValue={member.role}
        onChange={(event) => event.currentTarget.form?.requestSubmit()}
        className="h-9 w-44"
      >
        {!known ? <option value={member.role}>{roleLabel(member.role)}</option> : null}
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </Select>
      <FormError message={state.error} />
    </form>
  )
}

function RevokeButton({ member }: { member: StaffMember }) {
  const [open, setOpen] = useState(false)
  const [state, formAction] = useActionState(revokeMembership, initialState)

  return (
    <>
      <Button variant="ghost" size="sm" onClick={() => setOpen(true)}>
        Отключить доступ
      </Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Отключить доступ?"
        description={`${member.fullName ?? member.email ?? 'Участник'} потеряет доступ к центру. Карточка специалиста и вся история занятий останутся.`}
      >
        <FormError message={state.error} />

        <div className="flex gap-2">
          <form action={formAction}>
            <input type="hidden" name="userId" value={member.userId} />
            <Button type="submit" variant="destructive">
              Отключить
            </Button>
          </form>
          <Button type="button" variant="outline" onClick={() => setOpen(false)}>
            Отмена
          </Button>
        </div>
      </Dialog>
    </>
  )
}

export function StaffTable({
  members,
  actorRole,
  currentUserId,
  timeZone,
  payers,
}: {
  members: StaffMember[]
  actorRole: string
  currentUserId: string
  timeZone: string
  payers: PayerOption[]
}) {
  if (members.length === 0) {
    return <p className="text-sm text-muted-foreground">В центре пока только вы.</p>
  }

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>ФИО</TableHead>
          <TableHead>Email</TableHead>
          <TableHead>Роль</TableHead>
          <TableHead>Статус</TableHead>
          <TableHead className="text-right">Действия</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {members.map((member) => (
          <TableRow key={member.userId}>
            <TableCell className="font-medium">
              {member.fullName ?? member.payerName ?? '—'}
              {member.userId === currentUserId ? (
                <span className="ml-2 text-xs text-muted-foreground">это вы</span>
              ) : null}
              {/* Родитель без карточки — то, из-за чего он видит пустой кабинет (0060). */}
              {member.role === 'parent' && !member.payerId ? (
                <span className="block text-xs font-normal text-destructive">Плательщик не привязан</span>
              ) : null}
            </TableCell>
            <TableCell className="text-muted-foreground">{member.email ?? '—'}</TableCell>
            <TableCell>
              {member.userId === currentUserId ? (
                <span className="text-sm">{roleLabel(member.role)}</span>
              ) : (
                <RoleSelect member={member} actorRole={actorRole} />
              )}
            </TableCell>
            <TableCell>
              <span className={member.isActive ? 'text-sm' : 'text-sm text-muted-foreground'}>
                {member.isActive ? 'Активен' : 'Отключён'}
              </span>
            </TableCell>
            <TableCell className="text-right">
              <div className="flex flex-wrap justify-end gap-2">
                {member.teacherId ? (
                  <VacationDialog
                    teacherId={member.teacherId}
                    teacherName={member.fullName ?? 'специалист'}
                    timeZone={timeZone}
                  />
                ) : null}
                {member.role === 'parent' ? <LinkPayerDialog member={member} payers={payers} /> : null}
                {member.userId === currentUserId ? null : <RevokeButton member={member} />}
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

export function StaffNotice({ message }: { message?: string }) {
  return <FormNotice message={message} />
}
