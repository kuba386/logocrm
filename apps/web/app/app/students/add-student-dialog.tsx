'use client'

import { useActionState, useState } from 'react'
import { useFormStatus } from 'react-dom'
import { createStudent, findPayerByPhone, type PayerMatch, type StudentState } from './actions'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { FormError, FormNotice } from '@/components/ui/alert'
import { PAYER_RELATIONS } from '@/lib/students'

const initialState: StudentState = {}

export type TeacherOption = { id: string; fullName: string }

function SubmitButton() {
  const { pending } = useFormStatus()
  return (
    <Button type="submit" disabled={pending}>
      {pending ? 'Сохраняем…' : 'Добавить ученика'}
    </Button>
  )
}

export function AddStudentDialog({
  teachers,
  presetPayer,
  label = 'Добавить ученика',
}: {
  teachers: TeacherOption[]
  presetPayer?: { id: string; fullName: string }
  label?: string
}) {
  const [open, setOpen] = useState(false)
  const [state, formAction] = useActionState(createStudent, initialState)

  const [phone, setPhone] = useState('')
  const [match, setMatch] = useState<PayerMatch | null>(null)
  const [linkExisting, setLinkExisting] = useState(Boolean(presetPayer))
  const [checking, setChecking] = useState(false)

  // Ищем плательщика, когда администратор уходит из поля телефона.
  async function checkPhone() {
    if (!phone.trim()) {
      setMatch(null)
      return
    }
    setChecking(true)
    const found = await findPayerByPhone(phone)
    setMatch(found)
    setLinkExisting(Boolean(found))
    setChecking(false)
  }

  const payerId = presetPayer?.id ?? (linkExisting ? match?.id : undefined)

  return (
    <>
      <Button onClick={() => setOpen(true)}>{label}</Button>

      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        title="Новый ученик"
        description="Сначала плательщик — родитель или опекун, потом сам ребёнок."
      >
        <form action={formAction} className="space-y-5">
          {payerId ? <input type="hidden" name="payerId" value={payerId} /> : null}

          <section className="space-y-3">
            <h3 className="text-sm font-medium">1. Плательщик</h3>

            {presetPayer ? (
              <p className="rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground">
                Ребёнок будет привязан к {presetPayer.fullName}
              </p>
            ) : (
              <>
                <div className="space-y-2">
                  <Label htmlFor="payerPhone">Телефон</Label>
                  <Input
                    id="payerPhone"
                    name="payerPhone"
                    placeholder="+996 700 123 456"
                    value={phone}
                    onChange={(event) => setPhone(event.target.value)}
                    onBlur={checkPhone}
                    required={!linkExisting}
                  />
                  {checking ? <p className="text-xs text-muted-foreground">Проверяем…</p> : null}
                </div>

                {match ? (
                  <div className="space-y-2 rounded-md border border-border bg-muted/40 p-3">
                    <p className="text-sm">
                      Такой номер уже есть: <span className="font-medium">{match.fullName}</span>,
                      детей — {match.childrenCount}.
                    </p>
                    <div className="flex flex-wrap gap-2">
                      <Button
                        type="button"
                        size="sm"
                        variant={linkExisting ? 'default' : 'outline'}
                        onClick={() => setLinkExisting(true)}
                      >
                        Привязать к {match.fullName}
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant={linkExisting ? 'outline' : 'default'}
                        onClick={() => setLinkExisting(false)}
                      >
                        Это другой человек
                      </Button>
                    </div>
                    {!linkExisting ? (
                      <p className="text-xs text-muted-foreground">
                        Один и тот же номер у двух плательщиков в центре не сохранится — поменяйте
                        номер или привяжите к существующему.
                      </p>
                    ) : null}
                  </div>
                ) : null}

                {!linkExisting ? (
                  <>
                    <div className="space-y-2">
                      <Label htmlFor="payerFullName">ФИО плательщика</Label>
                      <Input id="payerFullName" name="payerFullName" placeholder="Иванова Айгуль" required />
                    </div>

                    <div className="space-y-2">
                      <Label htmlFor="payerRelation">Кем приходится</Label>
                      <Select id="payerRelation" name="payerRelation" defaultValue="мама">
                        {PAYER_RELATIONS.map((relation) => (
                          <option key={relation} value={relation}>
                            {relation}
                          </option>
                        ))}
                      </Select>
                    </div>
                  </>
                ) : null}
              </>
            )}
          </section>

          <section className="space-y-3 border-t border-border pt-4">
            <h3 className="text-sm font-medium">2. Ребёнок</h3>

            <div className="space-y-2">
              <Label htmlFor="fullName">ФИО ребёнка</Label>
              <Input id="fullName" name="fullName" placeholder="Данияр Иванов" required minLength={2} />
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label htmlFor="birthDate">Дата рождения</Label>
                <Input id="birthDate" name="birthDate" type="date" />
              </div>
              <div className="space-y-2">
                <Label htmlFor="gender">Пол</Label>
                <Select id="gender" name="gender" defaultValue="">
                  <option value="">Не указан</option>
                  <option value="м">Мальчик</option>
                  <option value="ж">Девочка</option>
                </Select>
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="primaryTeacherId">Специалист</Label>
              <Select id="primaryTeacherId" name="primaryTeacherId" defaultValue="">
                <option value="">Пока не назначен</option>
                {teachers.map((teacher) => (
                  <option key={teacher.id} value={teacher.id}>
                    {teacher.fullName}
                  </option>
                ))}
              </Select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="source">Откуда пришли</Label>
              <Input id="source" name="source" placeholder="Instagram, рекомендация, сайт" />
            </div>

            <div className="space-y-2">
              <Label htmlFor="notes">Заметка</Label>
              <Input id="notes" name="notes" placeholder="Что важно помнить" />
            </div>
          </section>

          <FormError message={state.error} />
          <FormNotice message={state.notice} />

          <div className="flex gap-2">
            <SubmitButton />
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Отмена
            </Button>
          </div>
        </form>
      </Dialog>
    </>
  )
}
