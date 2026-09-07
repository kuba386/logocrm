'use client'

import { useActionState, useEffect, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { createInvitation, type StaffState } from './actions'
import { Button, buttonVariants } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { invitableRoles } from '@/lib/roles'

const initialState: StaffState = {}

export type TeacherOption = { id: string; fullName: string }

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={pending}>
      {pending ? 'Создаём…' : 'Создать ссылку'}
    </Button>
  )
}

export function InviteDialog({
  actorRole,
  teachers,
}: {
  actorRole: string
  teachers: TeacherOption[]
}) {
  const [open, setOpen] = useState(false)
  const [role, setRole] = useState('teacher')
  const [teacherId, setTeacherId] = useState('')
  const [state, formAction] = useActionState(createInvitation, initialState)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    setCopied(false)
  }, [state.inviteUrl])

  const roles = invitableRoles(actorRole)

  async function copyLink() {
    if (!state.inviteUrl) return
    await navigator.clipboard.writeText(state.inviteUrl)
    setCopied(true)
  }

  return (
    <>
      <Button onClick={() => setOpen(true)}>Пригласить</Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Приглашение сотрудника"
        description="Создайте ссылку и отправьте её человеку. Ссылка действует 7 дней."
      >
        {state.inviteUrl ? (
          <div className="space-y-4">
            <FormNotice message="Ссылка готова. Отправьте её сотруднику." />

            <div className="rounded-md border border-border bg-muted p-3 text-xs break-all">
              {state.inviteUrl}
            </div>

            <div className="flex flex-wrap gap-2">
              <Button type="button" onClick={copyLink}>
                {copied ? 'Скопировано' : 'Скопировать ссылку'}
              </Button>
              <a
                className={buttonVariants({ variant: 'outline' })}
                href={`https://wa.me/?text=${encodeURIComponent(
                  `Здравствуйте! Приглашаю вас в LogoCRM. Перейдите по ссылке, чтобы получить доступ: ${state.inviteUrl}`,
                )}`}
                target="_blank"
                rel="noreferrer"
              >
                Отправить в WhatsApp
              </a>
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                Закрыть
              </Button>
            </div>
          </div>
        ) : (
          <form action={formAction} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="role">Роль</Label>
              <Select id="role" name="role" value={role} onChange={(e) => setRole(e.target.value)}>
                {roles.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </Select>
            </div>

            {role === 'teacher' && teachers.length > 0 ? (
              <div className="space-y-2">
                <Label htmlFor="teacherId">Карточка специалиста</Label>
                <Select
                  id="teacherId"
                  name="teacherId"
                  value={teacherId}
                  onChange={(e) => setTeacherId(e.target.value)}
                >
                  <option value="">Создать новую</option>
                  {teachers.map((teacher) => (
                    <option key={teacher.id} value={teacher.id}>
                      {teacher.fullName}
                    </option>
                  ))}
                </Select>
              </div>
            ) : null}

            {role === 'teacher' && teacherId === '' ? (
              <div className="space-y-2">
                <Label htmlFor="fullName">ФИО</Label>
                <Input id="fullName" name="fullName" placeholder="Айгуль Кадырова" />
              </div>
            ) : null}

            <div className="space-y-2">
              <Label htmlFor="phone">Телефон</Label>
              <Input id="phone" name="phone" placeholder="+996 700 123 456" />
            </div>

            <div className="space-y-2">
              <Label htmlFor="email">Email (необязательно)</Label>
              <Input id="email" name="email" type="email" />
            </div>

            <FormError message={state.error} />

            <div className="flex gap-2">
              <SubmitButton />
              <Button type="button" variant="outline" onClick={() => setOpen(false)}>
                Отмена
              </Button>
            </div>
          </form>
        )}
      </Dialog>
    </>
  )
}
