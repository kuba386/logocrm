'use client'

import { startTransition, useActionState, useEffect, useState, type FormEvent } from 'react'
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
/** Карточка плательщика для выбора при приглашении родителя (0060). */
export type PayerOption = { id: string; fullName: string; phone: string | null; children: string[] }

function SubmitButton({ pending }: { pending: boolean }) {
  return (
    <Button type="submit" disabled={pending}>
      {pending ? 'Создаём…' : 'Создать ссылку'}
    </Button>
  )
}

/**
 * Выбор плательщика при приглашении родителя. Роль «Родитель» без карточки
 * база не выпускает (0060): либо существующая карточка, либо новая по ФИО и
 * телефону — и тогда форма говорит об этом прямо, а не после входа родителя
 * в пустой кабинет.
 */
export function PayerPicker({
  payers,
  payerId,
  onChange,
}: {
  payers: PayerOption[]
  payerId: string
  onChange: (value: string) => void
}) {
  const selected = payers.find((payer) => payer.id === payerId)
  return (
    <>
      <div className="space-y-2">
        <Label htmlFor="payerId">Плательщик</Label>
        <Select id="payerId" name="payerId" value={payerId} onChange={(e) => onChange(e.target.value)}>
          <option value="">Новая карточка плательщика</option>
          {payers.map((payer) => (
            <option key={payer.id} value={payer.id}>
              {payer.fullName}
              {payer.phone ? ` · ${payer.phone}` : ''}
            </option>
          ))}
        </Select>
      </div>

      {selected ? (
        <p className="text-sm text-muted-foreground" data-testid="payer-children">
          {selected.children.length > 0
            ? `Дети: ${selected.children.join(', ')}`
            : 'К этой карточке пока не привязан ни один ребёнок — родитель ничего не увидит, пока ребёнка не добавят на карточке ученика.'}
        </p>
      ) : (
        <FormNotice message="Будет создана новая карточка плательщика без детей. Если родитель уже есть в базе — выберите его из списка, иначе появится дубль. Ребёнка к новой карточке привяжите на карточке ученика." />
      )}
    </>
  )
}

/**
 * Каждое открытие окна — чистая форма. Состояние useActionState не
 * сбрасывается, поэтому раньше окно после первой ссылки навсегда показывало
 * её же: второго специалиста было не пригласить без перезагрузки страницы.
 * Теперь тело окна пересоздаётся (key) при закрытии и по «Пригласить ещё».
 */
export function InviteDialog(props: { actorRole: string; teachers: TeacherOption[]; payers: PayerOption[] }) {
  const [open, setOpen] = useState(false)
  const [round, setRound] = useState(0)

  function close() {
    setOpen(false)
    setRound((r) => r + 1)
  }

  return (
    <>
      <Button onClick={() => setOpen(true)}>Пригласить</Button>

      <Dialog
        open={open}
        onClose={close}
        title="Приглашение"
        description="Создайте ссылку и отправьте её человеку. Ссылка сотрудника действует 7 дней, родителя — 3 дня: она открывает данные его семьи, отправляйте лично."
      >
        <InviteDialogBody key={round} {...props} onClose={close} onAgain={() => setRound((r) => r + 1)} />
      </Dialog>
    </>
  )
}

function InviteDialogBody({
  actorRole,
  teachers,
  payers,
  onClose,
  onAgain,
}: {
  actorRole: string
  teachers: TeacherOption[]
  payers: PayerOption[]
  onClose: () => void
  onAgain: () => void
}) {
  const [role, setRole] = useState('teacher')
  const [teacherId, setTeacherId] = useState('')
  const [payerId, setPayerId] = useState('')
  const [state, formAction, pending] = useActionState(createInvitation, initialState)

  // Не <form action>: React 19 после такого действия сбрасывает форму, и при
  // отказе (лимит тарифа, кривой телефон) select «Роль» визуально прыгал на
  // первый вариант «Администратор» — при поле специалиста под ним. Повторное
  // «Создать ссылку» отправило бы приглашение администратора. Через onSubmit
  // сброса нет: введённое остаётся, роль — та, что выбрана.
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const formData = new FormData(event.currentTarget)
    startTransition(() => formAction(formData))
  }
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    setCopied(false)
  }, [state.inviteUrl])

  const roles = invitableRoles(actorRole)
  const isParent = role === 'parent'
  const newPayer = isParent && payerId === ''

  async function copyLink() {
    if (!state.inviteUrl) return
    await navigator.clipboard.writeText(state.inviteUrl)
    setCopied(true)
  }

  return state.inviteUrl ? (
    <div className="space-y-4">
      <FormNotice
        message={
          state.notice ??
          'Ссылка готова. Отправьте её человеку — открыть и принять её должен он сам. Если откроете ссылку у себя, где вы уже вошли, она не сработает: проверять — только в режиме инкогнито.'
        }
      />

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
        <Button type="button" variant="outline" onClick={onAgain}>
          Пригласить ещё
        </Button>
        <Button type="button" variant="ghost" onClick={onClose}>
          Закрыть
        </Button>
      </div>
    </div>
  ) : (
    <form onSubmit={submit} className="space-y-4">
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

      {isParent ? <PayerPicker payers={payers} payerId={payerId} onChange={setPayerId} /> : null}

      {(role === 'teacher' && teacherId === '') || newPayer ? (
        <div className="space-y-2">
          <Label htmlFor="fullName">{newPayer ? 'ФИО плательщика' : 'ФИО'}</Label>
          <Input id="fullName" name="fullName" placeholder="Айгуль Кадырова" required={newPayer} />
        </div>
      ) : null}

      {/* У выбранной карточки телефон уже есть — база кладёт его в приглашение сама. */}
      {isParent && !newPayer ? null : (
        <div className="space-y-2">
          <Label htmlFor="phone">{newPayer ? 'Телефон плательщика' : 'Телефон'}</Label>
          <Input id="phone" name="phone" placeholder="+996 700 123 456" required={newPayer} />
        </div>
      )}

      <div className="space-y-2">
        <Label htmlFor="email">Email (для заметки)</Label>
        <Input id="email" name="email" type="email" aria-describedby="email-hint" />
        <p id="email-hint" className="text-xs text-muted-foreground">
          Письмо на него не уходит — ссылку отправьте сами: копией или в WhatsApp.
        </p>
      </div>

      <FormError message={state.error} />

      <div className="flex gap-2">
        <SubmitButton pending={pending} />
        <Button type="button" variant="outline" onClick={onClose}>
          Отмена
        </Button>
      </div>
    </form>
  )
}
