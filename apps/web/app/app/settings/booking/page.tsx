import Link from 'next/link'
import { redirect } from 'next/navigation'
import { workHoursSummary } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { siteUrl } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { CopyButton } from '@/components/ui/copy-button'
import { StatusBadge } from '@/components/ui/status-badge'
import { BookingToggleForm } from '../plan/booking-panel'
import { BookingSettingsForm, MODE_LABELS, TeacherBookingDialog, type BookingMode, type WorkInterval } from './booking-forms'

export const metadata = { title: 'Онлайн-запись — LogoCRM' }

/**
 * Онлайн-запись (0109): ссылка для родителей, горизонт и шаг витрины, режим и
 * рабочие часы каждого специалиста. Заявки и лист ожидания — «Заявки».
 */
export default async function BookingSettingsPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const [{ data: center }, { data: teachers, error: teachersError }, { data: hours }] = await Promise.all([
    supabase.from('centers').select('slug, settings').maybeSingle(),
    supabase
      .from('teachers')
      .select('id, full_name, booking_mode')
      .is('deleted_at', null)
      .eq('is_active', true)
      .order('full_name'),
    supabase.from('teacher_work_hours').select('teacher_id, weekday, starts_at, ends_at').order('weekday').order('starts_at'),
  ])

  const settings = (center?.settings ?? {}) as Record<string, unknown>
  const enabled = Boolean(settings.booking_enabled)
  const horizon = typeof settings.booking_horizon_days === 'number' ? settings.booking_horizon_days : 14
  const step = typeof settings.booking_step_min === 'number' ? settings.booking_step_min : 30
  const link = `${siteUrl()}/book/${center?.slug ?? ''}`

  const hoursByTeacher = new Map<string, WorkInterval[]>()
  for (const h of hours ?? []) {
    hoursByTeacher.set(h.teacher_id, [...(hoursByTeacher.get(h.teacher_id) ?? []), h])
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Онлайн-запись</h1>
        <p className="text-sm text-muted-foreground">
          Родители выбирают свободное время на сайте или встают в лист ожидания. Заявки и лист ожидания — в разделе{' '}
          <Link href="/app/bookings" className="text-primary underline-offset-4 hover:underline">
            «Заявки»
          </Link>
          .
        </p>
      </div>

      <Card>
        <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
          <div className="space-y-1.5">
            <CardTitle>Ссылка для родителей</CardTitle>
            <CardDescription>Поставьте её в шапку Instagram, сторис «Лист ожидания» и ответ в Директе.</CardDescription>
          </div>
          <StatusBadge tone={enabled ? 'success' : 'neutral'}>{enabled ? 'Открыта' : 'Закрыта'}</StatusBadge>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-wrap items-center gap-2">
            <code className="break-all rounded-md bg-muted px-2 py-1 text-sm">{link}</code>
            <CopyButton text={link} />
          </div>
          <BookingToggleForm enabled={enabled} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Свободные окна</CardTitle>
          <CardDescription>Для специалистов в режиме «По рабочим часам».</CardDescription>
        </CardHeader>
        <CardContent>
          <BookingSettingsForm horizon={horizon} step={step} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Специалисты</CardTitle>
          <CardDescription>Режим записи и рабочие часы. Занятия и заявки из окон вычитаются сами.</CardDescription>
        </CardHeader>
        <CardContent>
          {teachersError ? (
            <p role="alert" className="text-sm text-destructive">
              {toAppError(teachersError, 'Не удалось загрузить специалистов').message}
            </p>
          ) : !teachers || teachers.length === 0 ? (
            <p className="text-sm text-muted-foreground">Активных специалистов нет.</p>
          ) : (
            <ul className="divide-y divide-border">
              {teachers.map((tc) => {
                const mode = (tc.booking_mode as BookingMode) ?? 'any'
                const list = hoursByTeacher.get(tc.id) ?? []
                return (
                  <li key={tc.id} className="flex flex-wrap items-center justify-between gap-3 py-3">
                    <div className="min-w-0 space-y-0.5">
                      <p className="font-medium">{tc.full_name}</p>
                      <p className="text-sm text-muted-foreground">
                        {MODE_LABELS[mode]}
                        {mode === 'hours' ? ` · ${list.length > 0 ? workHoursSummary(list) : 'часы не заданы — окон нет'}` : ''}
                      </p>
                    </div>
                    <TeacherBookingDialog teacherId={tc.id} teacherName={tc.full_name} mode={mode} intervals={list} />
                  </li>
                )
              })}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
