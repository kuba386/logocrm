import Link from 'next/link'
import { redirect } from 'next/navigation'
import { ageLabel, formatKgPhone, WEEKDAY_SHORT } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { EmptyState } from '@/components/ui/empty-state'
import { Label } from '@/components/ui/label'
import { PageHeader } from '@/components/ui/page-header'
import { Select } from '@/components/ui/select'
import { toAppError } from '@/lib/errors'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { t } from '@/lib/messages'
import { isFrontDesk } from '@/lib/roles'
import { cn } from '@/lib/utils'
import { centerTimeZone, formatInTimeZone } from '@/lib/timezone'
import { BookingQueueRow } from './queue-row'
import { WaitlistRow } from './waitlist-row'

export const metadata = { title: 'Заявки с сайта — LogoCRM' }

type Row = {
  id: string
  child_name: string
  parent_name: string
  parent_phone: string
  starts_at: string
  teacher_id: string | null
  service_id: string | null
}

type WaitRow = {
  id: string
  child_name: string
  child_birth_date: string
  service_id: string
  teacher_id: string | null
  preferred_weekdays: number[] | null
  preferred_from: string | null
  preferred_to: string | null
  parent_name: string
  parent_phone: string
  comment: string | null
  status: string
  offered_at: string | null
  created_at: string
}

const UUID = /^[0-9a-f-]{36}$/i

/**
 * Очередь заявок с публичной витрины (0057) — только status='new';
 * подтверждённые/отклонённые уходят из очереди, но не удаляются (RPC
 * confirm_booking_request/decline_booking_request хранят историю).
 * Вкладка «Лист ожидания» (0109) — живые записи (ждёт / предложили время)
 * по времени подачи.
 */
export default async function BookingsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; service?: string; teacher?: string }>
}) {
  const params = await searchParams
  const tab = params.tab === 'waitlist' ? 'waitlist' : 'requests'
  const serviceFilter = params.service && UUID.test(params.service) ? params.service : ''
  const teacherFilter = params.teacher && UUID.test(params.teacher) ? params.teacher : ''

  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!isFrontDesk(role)) redirect('/app')

  const { data: center } = await supabase.from('centers').select('settings').maybeSingle()
  const timezone = centerTimeZone(center?.settings)

  let waitQuery = supabase
    .from('waitlist_entries')
    .select(
      'id, child_name, child_birth_date, service_id, teacher_id, preferred_weekdays, preferred_from, preferred_to, parent_name, parent_phone, comment, status, offered_at, created_at',
    )
    .in('status', ['waiting', 'offered'])
    .order('created_at')
  if (serviceFilter) waitQuery = waitQuery.eq('service_id', serviceFilter)
  // Запись без специалиста подходит любому — при фильтре по специалисту видна тоже.
  if (teacherFilter) waitQuery = waitQuery.or(`teacher_id.eq.${teacherFilter},teacher_id.is.null`)

  // teacher_id/service_id несут только составной FK (center_id, X) — PostgREST
  // embed через них нигде не используется (0022 Р6, PGRST201/тихая пустота),
  // поэтому имена подтягиваются отдельным запросом и Map, как в schedule/page.tsx.
  const [{ data: rows, error }, waitResult, { count: waitCount }, { data: teachers }, { data: services }] = await Promise.all([
    supabase
      .from('booking_requests')
      .select('id, child_name, parent_name, parent_phone, starts_at, teacher_id, service_id')
      .eq('status', 'new')
      .order('starts_at')
      .returns<Row[]>(),
    tab === 'waitlist' ? waitQuery.returns<WaitRow[]>() : Promise.resolve({ data: null, error: null }),
    supabase.from('waitlist_entries').select('id', { count: 'exact', head: true }).in('status', ['waiting', 'offered']),
    supabase.from('teachers').select('id, full_name, deleted_at').order('full_name'),
    supabase.from('services').select('id, name, kind, deleted_at').order('name'),
  ])

  const teacherNames = new Map((teachers ?? []).map((tc) => [tc.id, tc.full_name]))
  const serviceNames = new Map((services ?? []).map((s) => [s.id, s.name]))
  const tabs = [
    { key: 'requests', label: t('bookingQueue', 'tabRequests'), count: rows?.length ?? 0, href: '/app/bookings' },
    { key: 'waitlist', label: t('bookingQueue', 'tabWaitlist'), count: waitCount ?? 0, href: '/app/bookings?tab=waitlist' },
  ]

  return (
    <div className="space-y-6">
      <PageHeader
        title={t('bookingQueue', 'title')}
        description={tab === 'waitlist' ? t('bookingQueue', 'waitlistDescription') : t('bookingQueue', 'description')}
      />

      <nav aria-label={t('bookingQueue', 'title')} className="flex gap-2">
        {tabs.map((item) => (
          <Link
            key={item.key}
            href={item.href}
            aria-current={tab === item.key ? 'page' : undefined}
            className={cn(
              'inline-flex min-h-11 items-center gap-2 rounded-md border px-4 text-sm font-medium transition-colors',
              tab === item.key
                ? 'border-primary bg-primary text-primary-foreground'
                : 'border-border bg-background text-foreground hover:bg-accent',
            )}
          >
            {item.label}
            <span className="tabular-nums">{item.count}</span>
          </Link>
        ))}
      </nav>

      {tab === 'requests' ? (
        <Card>
          <CardContent className="pt-6">
            {error ? (
              <p role="alert" className="text-sm text-destructive">
                {toAppError(error, 'Не удалось загрузить заявки').message}
              </p>
            ) : !rows || rows.length === 0 ? (
              <EmptyState title={t('bookingQueue', 'empty')} />
            ) : (
              // На телефоне 7 колонок не помещались — кнопки уезжали за край. Там
              // родитель, телефон, специалист и услуга идут под именем ребёнка.
              <Table className="max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(4)]:hidden max-sm:[&_tr>*:nth-child(5)]:hidden max-sm:[&_tr>*:nth-child(6)]:hidden">
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('bookingQueue', 'colTime')}</TableHead>
                    <TableHead>{t('bookingQueue', 'colChild')}</TableHead>
                    <TableHead>{t('bookingQueue', 'colParent')}</TableHead>
                    <TableHead>{t('bookingQueue', 'colPhone')}</TableHead>
                    <TableHead>{t('bookingQueue', 'colTeacher')}</TableHead>
                    <TableHead>{t('bookingQueue', 'colService')}</TableHead>
                    <TableHead />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((r) => (
                    <TableRow key={r.id}>
                      <TableCell>{formatInTimeZone(r.starts_at, timezone, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</TableCell>
                      <TableCell>
                        {r.child_name}
                        <span className="block text-xs text-muted-foreground sm:hidden">
                          {r.parent_name} ·{' '}
                          <a href={`tel:${r.parent_phone}`} className="text-primary underline-offset-4 hover:underline">
                            {formatKgPhone(r.parent_phone)}
                          </a>
                        </span>
                        <span className="block text-xs text-muted-foreground sm:hidden">
                          {(r.teacher_id && teacherNames.get(r.teacher_id)) ?? '—'} · {(r.service_id && serviceNames.get(r.service_id)) ?? '—'}
                        </span>
                      </TableCell>
                      <TableCell>{r.parent_name}</TableCell>
                      <TableCell className="whitespace-nowrap">
                        <a href={`tel:${r.parent_phone}`} className="hover:underline">
                          {formatKgPhone(r.parent_phone)}
                        </a>
                      </TableCell>
                      <TableCell>{(r.teacher_id && teacherNames.get(r.teacher_id)) ?? '—'}</TableCell>
                      <TableCell>{(r.service_id && serviceNames.get(r.service_id)) ?? '—'}</TableCell>
                      <TableCell>
                        <BookingQueueRow requestId={r.id} />
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardContent className="space-y-4 pt-6">
            <form method="get" className="flex flex-wrap items-end gap-3">
              <input type="hidden" name="tab" value="waitlist" />
              <div className="min-w-40 flex-1 space-y-1 sm:flex-none">
                <Label htmlFor="wl-filter-service">{t('bookingQueue', 'filterService')}</Label>
                <Select id="wl-filter-service" name="service" defaultValue={serviceFilter}>
                  <option value="">{t('bookingQueue', 'filterAll')}</option>
                  {(services ?? [])
                    .filter((s) => s.kind === 'individual' && !s.deleted_at)
                    .map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.name}
                      </option>
                    ))}
                </Select>
              </div>
              <div className="min-w-40 flex-1 space-y-1 sm:flex-none">
                <Label htmlFor="wl-filter-teacher">{t('bookingQueue', 'filterTeacher')}</Label>
                <Select id="wl-filter-teacher" name="teacher" defaultValue={teacherFilter}>
                  <option value="">{t('bookingQueue', 'filterAll')}</option>
                  {(teachers ?? [])
                    .filter((tc) => !tc.deleted_at)
                    .map((tc) => (
                      <option key={tc.id} value={tc.id}>
                        {tc.full_name}
                      </option>
                    ))}
                </Select>
              </div>
              <Button type="submit" variant="outline">
                {t('bookingQueue', 'filterApply')}
              </Button>
            </form>

            {waitResult.error ? (
              <p role="alert" className="text-sm text-destructive">
                {toAppError(waitResult.error, 'Не удалось загрузить лист ожидания').message}
              </p>
            ) : !waitResult.data || waitResult.data.length === 0 ? (
              <EmptyState
                title={serviceFilter || teacherFilter ? t('bookingQueue', 'waitlistEmptyFiltered') : t('bookingQueue', 'waitlistEmpty')}
              />
            ) : (
              <ul className="divide-y divide-border">
                {waitResult.data.map((w) => (
                  <li key={w.id} className="space-y-2 py-4 first:pt-0">
                    <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                      <p className="font-medium">
                        {w.child_name}
                        <span className="ml-2 text-sm font-normal text-muted-foreground">{ageLabel(w.child_birth_date)}</span>
                      </p>
                      <p className="text-xs text-muted-foreground">
                        {t('bookingQueue', 'colCreated')}:{' '}
                        {formatInTimeZone(w.created_at, timezone, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                        {' · '}
                        {w.status === 'offered' && w.offered_at
                          ? t('bookingQueue', 'statusOffered', {
                              date: formatInTimeZone(w.offered_at, timezone, { day: 'numeric', month: 'short' }),
                            })
                          : t('bookingQueue', 'statusWaiting')}
                      </p>
                    </div>
                    <dl className="grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
                      <dt className="text-muted-foreground">{t('bookingQueue', 'colService')}</dt>
                      <dd>
                        {serviceNames.get(w.service_id) ?? '—'} ·{' '}
                        {(w.teacher_id && teacherNames.get(w.teacher_id)) ?? t('bookingQueue', 'anyTeacher')}
                      </dd>
                      <dt className="text-muted-foreground">{t('bookingQueue', 'colWants')}</dt>
                      <dd>
                        {w.preferred_weekdays && w.preferred_weekdays.length > 0
                          ? w.preferred_weekdays.map((d) => WEEKDAY_SHORT[d - 1]).join(', ')
                          : t('bookingQueue', 'anyDay')}
                        {w.preferred_from && w.preferred_to
                          ? `, ${w.preferred_from.slice(0, 5)}–${w.preferred_to.slice(0, 5)}`
                          : ''}
                      </dd>
                      <dt className="text-muted-foreground">{t('bookingQueue', 'colParent')}</dt>
                      <dd>
                        {w.parent_name} ·{' '}
                        <a href={`tel:${w.parent_phone}`} className="text-primary underline-offset-4 hover:underline">
                          {formatKgPhone(w.parent_phone)}
                        </a>
                      </dd>
                      {w.comment ? (
                        <>
                          <dt className="text-muted-foreground">{t('bookingQueue', 'commentLabel')}</dt>
                          <dd className="whitespace-pre-line break-words">{w.comment}</dd>
                        </>
                      ) : null}
                    </dl>
                    <WaitlistRow entryId={w.id} />
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  )
}
