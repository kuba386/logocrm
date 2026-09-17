import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { centerTimeZone, isoDayInZone } from '@/lib/timezone'
import { STUDENT_STATUS_CLASSES, statusLabel, studentAge } from '@/lib/students'
import { StudentForm, type StudentFormValues } from './student-form'
import {
  SubscriptionsPanel,
  type AttendanceHistoryRow,
  type BalanceView,
  type SiblingOption,
  type SourceOption,
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
  const isFinance = role === 'finance'

  // Специалисту и родителю карточку отдаёт витрина — телефона в ней нет;
  // бухгалтеру — students_brief: ни телефона, ни заметок (0031).
  const { data: base } = isAdmin
    ? await supabase
        .from('students')
        .select(
          'id, full_name, birth_date, gender, status, primary_teacher_id, source, notes, payer_id, created_at',
        )
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    : isFinance
      ? await supabase.rpc('students_brief').eq('id', id).maybeSingle()
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
    gender: 'gender' in base ? base.gender : null,
    status: base.status ?? 'active',
    primaryTeacherId: base.primary_teacher_id,
    source: 'source' in base ? (base.source ?? null) : null,
    notes: 'notes' in base ? base.notes : null,
  }

  const payer = isAdmin && 'payer_id' in base && base.payer_id
    ? (
        await supabase
          .from('payers')
          .select('id, full_name, phone, phone_alt, email, relation, notes')
          .eq('id', base.payer_id)
          .maybeSingle()
      ).data
    : isFinance && 'payer_id' in base && base.payer_id
      ? (await supabase.rpc('payers_brief').eq('id', base.payer_id).maybeSingle()).data
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
    sources: SourceOption[]
    today: string
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
      { data: sourceRows },
    ] = await Promise.all([
        supabase
          .from('subscriptions')
          .select('id, type_id, price_tiyin, starts_at, ends_at')
          .eq('student_id', id)
          .is('deleted_at', null)
          .order('created_at', { ascending: false }),
        // Без фильтров: имя нужно и для архивных/неактивных типов — они
        // остаются на уже проданных абонементах (находка C, архив 0012).
        // В форму продажи ниже попадают только is_active и не архивные.
        supabase
          .from('subscription_types')
          .select('id, name, kind, price_tiyin, lessons_count, period_days, is_active, deleted_at')
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
        // Источники оплаты для формы продажи: только живые; архивный источник
        // record_payment примет (известное ограничение 0016), но предлагать его
        // в форме незачем.
        supabase
          .from('payment_sources')
          .select('id, name')
          .eq('is_active', true)
          .is('deleted_at', null)
          .order('sort'),
      ])

    const typeNameById = new Map((typeRows ?? []).map((t) => [t.id, t.name]))
    const subscriptionIds = (subsRows ?? []).map((row) => row.id)

    // Оплата и рассрочка — с сервера (subscription_payment_summary,
    // installments_view), не из суммы платежей в браузере.
    const [paymentSummaries, { data: installmentRows }] = await Promise.all([
      Promise.all(
        subscriptionIds.map((subscriptionId) =>
          supabase.rpc('subscription_payment_summary', { p_subscription_id: subscriptionId }),
        ),
      ),
      subscriptionIds.length
        ? supabase
            .from('installments_view')
            .select('subscription_id, seq, due_date, amount_tiyin, state, cancelled_at')
            .in('subscription_id', subscriptionIds)
            .is('cancelled_at', null)
            .order('seq')
        : Promise.resolve({ data: [] as { subscription_id: string | null; seq: number | null; due_date: string | null; amount_tiyin: number | null; state: string | null; cancelled_at: string | null }[] }),
    ])

    // Границы текущей заморозки — из subscription_summary (freeze_from/
    // freeze_to, последний замороженный день уже посчитан на сервере как
    // upper(period) - 1), а не разбором daterange-текста на клиенте: тот
    // разбор был вторым источником правды о заморозке рядом с subscription_
    // state и мог показать не ту же дату, что называет исключение при
    // отметке (0015_freeze_state_unification.sql, раздел 8).
    const summaries = await Promise.all(
      (subsRows ?? []).map((row) => supabase.rpc('subscription_summary', { p_subscription_id: row.id })),
    )

    const subscriptions: SubscriptionView[] = (subsRows ?? []).map((row, index) => {
      const summary = summaries[index]?.data?.[0]
      return {
        id: row.id,
        typeName: row.type_id ? (typeNameById.get(row.type_id) ?? 'Абонемент') : 'Абонемент',
        priceTiyin: row.price_tiyin,
        startsAt: row.starts_at,
        endsAt: row.ends_at,
        lessonsLeft: summary?.lessons_left ?? null,
        // '' — не значение state, честный "неизвестно" на случай отказа
        // RPC: подстановка 'active' сюда показала бы "Действует" для,
        // например, отменённого абонемента. SUBSCRIPTION_STATE_LABELS/
        // _CLASSES в subscriptions-panel.tsx уже падают на нейтральный
        // вид при неизвестном ключе (?? в обоих лукапах).
        state: summary?.state ?? '',
        freezeDays: summary?.freeze_days ?? 0,
        refundTiyin: summary?.refund_tiyin ?? 0,
        freezeFrom: summary?.freeze_from ?? null,
        freezeTo: summary?.freeze_to ?? null,
        paidTiyin: paymentSummaries[index]?.data?.[0]?.paid_tiyin ?? 0,
        paymentState: paymentSummaries[index]?.data?.[0]?.payment_state ?? '',
        installments: (installmentRows ?? [])
          .filter((r) => r.subscription_id === row.id && r.seq != null && r.due_date && r.amount_tiyin != null)
          .map((r) => ({
            seq: r.seq as number,
            dueDate: r.due_date as string,
            amountTiyin: r.amount_tiyin as number,
            state: r.state ?? '',
          })),
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
      types: (typeRows ?? [])
        .filter((t) => t.is_active && !t.deleted_at)
        .map((t) => ({
          id: t.id,
          name: t.name,
          kind: t.kind,
          priceTiyin: t.price_tiyin,
          lessonsCount: t.lessons_count,
          periodDays: t.period_days,
        })),
      siblings: (siblingRows ?? []).map((s) => ({ id: s.id, fullName: s.full_name })),
      sources: (sourceRows ?? []).map((s) => ({ id: s.id, name: s.name })),
      today: isoDayInZone(new Date(), centerTimeZone(center?.settings)),
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
            {payer ? 'Контакты для связи с семьёй.' : 'Контакты видны администратору центра.'}
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
                {isAdmin ? (
                  <Link
                    href={`/app/payers/${payer.id}`}
                    className={buttonVariants({ variant: 'ghost', size: 'sm' })}
                  >
                    Карточка плательщика
                  </Link>
                ) : null}
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
