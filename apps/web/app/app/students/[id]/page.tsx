import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { centerTimeZone } from '@/lib/timezone'
import { STUDENT_STATUS_CLASSES, statusLabel, studentAge } from '@/lib/students'
import { StudentForm, type StudentFormValues } from './student-form'
import {
  SubscriptionsPanel,
  type AttendanceHistoryRow,
  type BalanceView,
  type SiblingOption,
  type SubscriptionTypeOption,
  type SubscriptionView,
} from './subscriptions-panel'

export const metadata = { title: 'Карточка ученика — LogoCRM' }

export default async function StudentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')

  const isAdmin = role === 'owner' || role === 'admin'

  // Специалисту и родителю карточку отдаёт витрина — телефона в ней нет.
  const { data: base } = isAdmin
    ? await supabase
        .from('students')
        .select(
          'id, full_name, birth_date, gender, status, primary_teacher_id, source, notes, payer_id, created_at',
        )
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    : await supabase
        .from('students_teacher_view')
        .select('id, full_name, birth_date, gender, status, primary_teacher_id, notes, payer_full_name')
        .eq('id', id)
        .maybeSingle()

  if (!base) notFound()

  const { data: teachers } = await supabase
    .from('teachers')
    .select('id, full_name')
    .is('deleted_at', null)
    .order('full_name')

  const teacherOptions = (teachers ?? []).map((teacher) => ({
    id: teacher.id,
    fullName: teacher.full_name,
  }))
  const teacherName = base.primary_teacher_id
    ? (teacherOptions.find((teacher) => teacher.id === base.primary_teacher_id)?.fullName ?? null)
    : null

  const student: StudentFormValues = {
    id: base.id as string,
    fullName: base.full_name ?? '—',
    birthDate: base.birth_date,
    gender: base.gender,
    status: base.status ?? 'active',
    primaryTeacherId: base.primary_teacher_id,
    source: 'source' in base ? (base.source ?? null) : null,
    notes: base.notes,
  }

  const payer = isAdmin && 'payer_id' in base && base.payer_id
    ? (
        await supabase
          .from('payers')
          .select('id, full_name, phone, phone_alt, email, relation, notes')
          .eq('id', base.payer_id)
          .maybeSingle()
      ).data
    : null

  const payerName = payer?.full_name ?? ('payer_full_name' in base ? base.payer_full_name : null)

  // История изменений — только владельцу и администратору: в audit_log лежат
  // прежние значения строк целиком.
  const { data: history } = isAdmin
    ? await supabase
        .from('audit_log')
        .select('id, action, at, new_data')
        .eq('table_name', 'students')
        .eq('row_id', id)
        .order('at', { ascending: false })
        .limit(20)
    : { data: null }

  const waNumber = payer?.phone ? whatsappNumber(payer.phone) : null

  // Специалисту — только слово (student_subscription_badge), admin/owner —
  // числа и действия (продать/заморозить/вернуть). Промт этапа 4: цифры и
  // деньги видит только тот, кто уходит открывать кабинет через дорогу.
  const subscriptionBadge = !isAdmin
    ? (await supabase.rpc('student_subscription_badge', { p_student_id: id })).data
    : null

  let subscriptionsSection: {
    balance: BalanceView
    subscriptions: SubscriptionView[]
    types: SubscriptionTypeOption[]
    siblings: SiblingOption[]
    attendanceHistory: AttendanceHistoryRow[]
    timeZone: string
  } | null = null

  if (isAdmin) {
    const payerId = 'payer_id' in base ? base.payer_id : null
    const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null

    const [
      { data: subsRows },
      { data: typeRows },
      { data: balanceRow },
      { data: siblingRows },
      { data: attendanceRows },
      { data: center },
    ] = await Promise.all([
        supabase
          .from('subscriptions')
          .select('id, type_id, price_tiyin, starts_at, ends_at, status')
          .eq('student_id', id)
          .is('deleted_at', null)
          .order('created_at', { ascending: false }),
        supabase
          .from('subscription_types')
          .select('id, name, kind, price_tiyin, lessons_count, period_days')
          .eq('is_active', true)
          .is('deleted_at', null)
          .order('name'),
        supabase
          .from('student_balance')
          .select('active_subscription_id, lessons_left, ends_at, debt_tiyin, overdrawn_tiyin')
          .eq('student_id', id)
          .maybeSingle(),
        payerId
          ? supabase.from('students').select('id, full_name').eq('payer_id', payerId).neq('id', id).is('deleted_at', null)
          : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
        supabase
          .from('attendance')
          .select('id, lesson_id, status_id, comment')
          .eq('student_id', id)
          .order('created_at', { ascending: false })
          .limit(20),
        supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle(),
      ])

    const typeNameById = new Map((typeRows ?? []).map((t) => [t.id, t.name]))
    const subscriptionIds = (subsRows ?? []).map((row) => row.id)

    const [summaries, { data: freezeRows }] = await Promise.all([
      Promise.all((subsRows ?? []).map((row) => supabase.rpc('subscription_summary', { p_subscription_id: row.id }))),
      subscriptionIds.length
        ? supabase.from('subscription_freezes').select('subscription_id, period').in('subscription_id', subscriptionIds)
        : Promise.resolve({ data: [] as { subscription_id: string; period: unknown }[] }),
    ])

    // period приходит текстом daterange: «[2026-09-12,2026-09-15)» или
    // «[2026-09-12,)» у открытой. Верхняя граница исключающая, поэтому
    // последний замороженный день — на сутки раньше: человеку показываем
    // «по 14.09», а не «по 15.09», иначе он насчитает лишний день.
    const freezeBySubscription = new Map<string, { from: string | null; to: string | null }>()
    for (const row of freezeRows ?? []) {
      const raw = typeof row.period === 'string' ? row.period : ''
      const match = /^[[(]([^,]*),([^)\]]*)[)\]]$/.exec(raw)
      if (!match) continue

      const from = (match[1] ?? '').replaceAll('"', '').trim()
      const upper = (match[2] ?? '').replaceAll('"', '').trim()
      const isOpen = upper === '' || upper === 'infinity'

      let to: string | null = null
      if (!isOpen) {
        const lastDay = new Date(`${upper}T00:00:00Z`)
        lastDay.setUTCDate(lastDay.getUTCDate() - 1)
        to = lastDay.toISOString().slice(0, 10)
      }

      freezeBySubscription.set(row.subscription_id, { from: from || null, to })
    }

    const subscriptions: SubscriptionView[] = (subsRows ?? []).map((row, index) => {
      const summary = summaries[index]?.data?.[0]
      const freeze = freezeBySubscription.get(row.id)
      return {
        id: row.id,
        typeName: row.type_id ? (typeNameById.get(row.type_id) ?? 'Абонемент') : 'Абонемент',
        priceTiyin: row.price_tiyin,
        startsAt: row.starts_at,
        endsAt: row.ends_at,
        lessonsLeft: summary?.lessons_left ?? null,
        state: summary?.state ?? row.status,
        freezeDays: summary?.freeze_days ?? 0,
        refundTiyin: summary?.refund_tiyin ?? 0,
        freezeFrom: freeze?.from ?? null,
        freezeTo: freeze?.to ?? null,
      }
    })

    const attendanceRowsData = attendanceRows ?? []
    const lessonIds = attendanceRowsData.map((a) => a.lesson_id)
    const statusIds = attendanceRowsData.map((a) => a.status_id).filter((v): v is string => Boolean(v))

    const [{ data: lessonRows }, { data: statusRows }] = await Promise.all([
      lessonIds.length
        ? supabase.from('lessons').select('id, starts_at').in('id', lessonIds)
        : Promise.resolve({ data: [] as { id: string; starts_at: string }[] }),
      statusIds.length
        ? supabase.from('attendance_statuses').select('id, name, color').in('id', statusIds)
        : Promise.resolve({ data: [] as { id: string; name: string; color: string }[] }),
    ])

    const lessonStartById = new Map((lessonRows ?? []).map((l) => [l.id, l.starts_at]))
    const statusById = new Map((statusRows ?? []).map((s) => [s.id, s]))

    subscriptionsSection = {
      balance: {
        lessonsLeft: balanceRow?.lessons_left ?? null,
        activeSubscriptionId: balanceRow?.active_subscription_id ?? null,
        endsAt: balanceRow?.ends_at ?? null,
        debtTiyin: balanceRow?.debt_tiyin ?? 0,
        overdrawnTiyin: balanceRow?.overdrawn_tiyin ?? 0,
      },
      subscriptions,
      types: (typeRows ?? []).map((t) => ({
        id: t.id,
        name: t.name,
        kind: t.kind,
        priceTiyin: t.price_tiyin,
        lessonsCount: t.lessons_count,
        periodDays: t.period_days,
      })),
      siblings: (siblingRows ?? []).map((s) => ({ id: s.id, fullName: s.full_name })),
      timeZone: centerTimeZone(center?.settings),
      attendanceHistory: attendanceRowsData.map((row) => {
        const status = row.status_id ? statusById.get(row.status_id) : undefined
        return {
          id: row.id,
          startsAt: lessonStartById.get(row.lesson_id) ?? '',
          statusName: status?.name ?? '—',
          statusColor: status?.color ?? 'green',
          comment: row.comment,
        }
      }),
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <Link href="/app/students" className="text-sm text-muted-foreground hover:underline">
          ← Все ученики
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h1 className="text-2xl font-semibold tracking-tight">{student.fullName}</h1>
          <span
            className={cn(
              'rounded-full px-2 py-0.5 text-xs',
              STUDENT_STATUS_CLASSES[student.status] ?? 'bg-muted text-muted-foreground',
            )}
          >
            {statusLabel(student.status)}
          </span>
        </div>
        <p className="text-sm text-muted-foreground">
          {studentAge(student.birthDate)}
          {teacherName ? ` · специалист: ${teacherName}` : ' · специалист не назначен'}
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Данные</CardTitle>
          <CardDescription>
            {isAdmin ? 'Изменения сохраняются сразу.' : 'Редактирование доступно администратору центра.'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <StudentForm student={student} teachers={teacherOptions} canEdit={isAdmin} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Плательщик</CardTitle>
          <CardDescription>
            {isAdmin ? 'Контакты для связи с семьёй.' : 'Контакты видны администратору центра.'}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="font-medium">{payerName ?? '—'}</p>

          {payer ? (
            <>
              <p className="text-sm text-muted-foreground">
                {payer.relation ?? 'родитель'} · {formatKgPhone(payer.phone)}
                {payer.email ? ` · ${payer.email}` : ''}
              </p>
              <div className="flex flex-wrap gap-2">
                <a href={`tel:${payer.phone}`} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                  Позвонить
                </a>
                {waNumber ? (
                  <a
                    href={`https://wa.me/${waNumber}`}
                    target="_blank"
                    rel="noreferrer"
                    className={buttonVariants({ variant: 'outline', size: 'sm' })}
                  >
                    WhatsApp
                  </a>
                ) : null}
                <Link
                  href={`/app/payers/${payer.id}`}
                  className={buttonVariants({ variant: 'ghost', size: 'sm' })}
                >
                  Карточка плательщика
                </Link>
              </div>
            </>
          ) : null}
        </CardContent>
      </Card>

      {subscriptionsSection ? (
        <Card>
          <CardHeader>
            <CardTitle>Абонементы и посещения</CardTitle>
            <CardDescription>Продажа, заморозка, возврат — суммы видит только администратор.</CardDescription>
          </CardHeader>
          <CardContent>
            <SubscriptionsPanel studentId={id} {...subscriptionsSection} />
          </CardContent>
        </Card>
      ) : subscriptionBadge ? (
        <Card>
          <CardHeader>
            <CardTitle>Абонемент</CardTitle>
          </CardHeader>
          <CardContent>
            <span
              className={cn(
                'rounded px-2 py-0.5 text-sm font-medium',
                subscriptionBadge === 'нет' ? 'bg-destructive/10 text-destructive' : 'bg-muted text-foreground',
              )}
            >
              {subscriptionBadge}
            </span>
          </CardContent>
        </Card>
      ) : null}

      {isAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>История</CardTitle>
            <CardDescription>Последние изменения карточки.</CardDescription>
          </CardHeader>
          <CardContent>
            {history && history.length > 0 ? (
              <ul className="space-y-2 text-sm">
                {history.map((entry) => (
                  <li key={entry.id} className="flex gap-3">
                    <span className="text-muted-foreground">
                      {new Date(entry.at).toLocaleString('ru-RU')}
                    </span>
                    <span>
                      {entry.action === 'INSERT' ? 'Создана' : entry.action === 'UPDATE' ? 'Изменена' : 'Удалена'}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-muted-foreground">Изменений пока нет.</p>
            )}
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}
