import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { dayInZone, formatInTimeZone, timeInZone } from '@/lib/timezone'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { cn } from '@/lib/utils'
import { label, t } from '@/lib/messages'

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

/**
 * Кабинет родителя — та же страница /app, ветвление по роли: «Одна
 * страница на все роли», CLAUDE.md. Отдельного /app/my не заводим.
 *
 * В отличие от специалиста (student_subscription_badge, только слово),
 * родителю — числа: student_balance пускает его к своим детям по RLS
 * (parent_of_student), и это его те же деньги.
 */
export async function ParentDashboard({ timeZone }: { timeZone: string }) {
  const supabase = await createClient()

  // Архивная карточка (дубль, ушедший ребёнок) родителю не показывается:
  // на дашборде она выглядела бы как второй ребёнок «без абонемента».
  const { data: children } = await supabase
    .from('students_teacher_view')
    .select('id, full_name, age_years')
    .neq('status', 'archived')
    .order('full_name')

  const childIds = (children ?? []).map((c) => c.id).filter((v): v is string => Boolean(v))

  if (childIds.length === 0) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold tracking-tight">Мои дети</h1>
        <Card>
          <CardContent className="pt-6 text-sm text-muted-foreground">
            Детей пока не привязано — обратитесь к администратору центра.
          </CardContent>
        </Card>
      </div>
    )
  }

  const nowIso = new Date().toISOString()

  const [{ data: balances }, { data: upcoming }] = await Promise.all([
    supabase
      .from('student_balance')
      .select('student_id, active_subscription_id, lessons_left, debt_tiyin, state')
      .in('student_id', childIds),
    supabase
      .from('lesson_participants')
      .select('student_id, lesson_id, starts_at')
      .in('student_id', childIds)
      .eq('status', 'planned')
      .gte('starts_at', nowIso)
      .order('starts_at'),
  ])

  const subscriptionIds = [...new Set((balances ?? []).map((b) => b.active_subscription_id).filter((v): v is string => Boolean(v)))]
  const { data: subscriptionRows } = subscriptionIds.length
    ? await supabase.from('subscriptions').select('id, lessons_total').in('id', subscriptionIds)
    : { data: [] }
  const totalBySubscription = new Map((subscriptionRows ?? []).map((s) => [s.id, s.lessons_total]))

  // Первое по времени занятие на ребёнка — участники уже отсортированы по starts_at.
  const nextByStudent = new Map<string, { lessonId: string; startsAt: string }>()
  for (const row of upcoming ?? []) {
    if (!row.student_id || nextByStudent.has(row.student_id)) continue
    nextByStudent.set(row.student_id, { lessonId: row.lesson_id, startsAt: row.starts_at })
  }

  const lessonIds = [...new Set([...nextByStudent.values()].map((v) => v.lessonId))]
  const { data: lessonRows } = lessonIds.length
    ? await supabase.from('lessons').select('id, teacher_id, substitute_teacher_id').in('id', lessonIds)
    : { data: [] }

  const teacherIds = [
    ...new Set((lessonRows ?? []).flatMap((l) => [l.teacher_id, l.substitute_teacher_id]).filter((v): v is string => Boolean(v))),
  ]
  const { data: teachers } = teacherIds.length
    ? await supabase.from('teachers').select('id, full_name').in('id', teacherIds)
    : { data: [] }

  const teacherName = new Map((teachers ?? []).map((tr) => [tr.id, tr.full_name]))
  const lessonById = new Map((lessonRows ?? []).map((l) => [l.id, l]))
  const balanceByStudent = new Map((balances ?? []).map((b) => [b.student_id, b]))

  // Платежи и рассрочка — свои по RLS (payments_parent_read,
  // installments_parent_read): родитель видит, что заплатил и что должен,
  // и ничего агрегированного по центру.
  const [{ data: paymentRows }, { data: installmentRows }] = await Promise.all([
    supabase
      .from('payments')
      .select('id, student_id, amount_tiyin, paid_at, kind')
      .order('paid_at', { ascending: false })
      .limit(10),
    supabase
      .from('installments_view')
      .select('id, student_id, due_date, amount_tiyin, state, cancelled_at')
      .is('cancelled_at', null)
      .neq('state', 'paid')
      .order('due_date')
      .limit(10),
  ])
  const payments = paymentRows ?? []
  const installments = (installmentRows ?? []).filter((r) => r.due_date && r.amount_tiyin != null)
  const childName = new Map((children ?? []).map((c) => [c.id ?? '', c.full_name ?? '']))

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold tracking-tight">Мои дети</h1>

      <div className="grid gap-4 sm:grid-cols-2">
        {(children ?? []).map((child) => {
          const childId = child.id ?? ''
          const balance = balanceByStudent.get(childId)
          const total = balance?.active_subscription_id ? totalBySubscription.get(balance.active_subscription_id) : null
          const next = nextByStudent.get(childId)
          const lesson = next ? lessonById.get(next.lessonId) : null
          const teacher = lesson ? (lesson.substitute_teacher_id ?? lesson.teacher_id) : null

          // state === 'frozen' проверяется до active_subscription_id: заморозка
          // не трогает lessons_left/ends_at (0015, раздел 5) — без этой ветки
          // родитель на паузе видел бы то же «N из M», что и до заморозки, без
          // намёка, что списаний сейчас нет.
          let balanceLabel: string
          if (!balance?.active_subscription_id) balanceLabel = 'нет абонемента'
          else if (balance.state === 'frozen') balanceLabel = 'заморожен'
          else if (balance.lessons_left == null) balanceLabel = 'без лимита'
          else balanceLabel = total != null ? `${balance.lessons_left} из ${total}` : `${balance.lessons_left}`

          return (
            <Card key={childId}>
              <CardHeader>
                <CardTitle className="flex items-baseline justify-between gap-2">
                  <span>{child.full_name}</span>
                  <span className="text-sm font-normal text-muted-foreground">
                    {child.age_years != null ? `${child.age_years} лет` : ''}
                  </span>
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-3 text-sm">
                <div className="flex justify-between">
                  <span className="text-muted-foreground">Осталось занятий</span>
                  <span className="font-medium">{balanceLabel}</span>
                </div>
                {balance?.debt_tiyin ? (
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Долг</span>
                    <span className="font-medium text-destructive">{formatSom(balance.debt_tiyin)}</span>
                  </div>
                ) : null}
                <div className="border-t border-border pt-3">
                  {next ? (
                    <>
                      <p className="font-medium">
                        {dayInZone(next.startsAt, timeZone)}, {timeInZone(next.startsAt, timeZone)}
                      </p>
                      {teacher ? <p className="text-muted-foreground">{teacherName.get(teacher) ?? '—'}</p> : null}
                    </>
                  ) : (
                    <p className="text-muted-foreground">Ближайших занятий не запланировано.</p>
                  )}
                </div>
              </CardContent>
            </Card>
          )
        })}
      </div>

      {installments.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('dashboard', 'parentInstallments')}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {installments.map((row) => (
              <p key={row.id as string} className={cn('flex justify-between gap-2', row.state === 'overdue' && 'text-destructive')}>
                <span className="truncate">{childName.get(row.student_id ?? '') || '—'}</span>
                <span className="shrink-0">
                  {t('dashboard', row.state === 'overdue' ? 'parentInstallmentOverdue' : 'parentInstallmentDue', {
                    amount: formatSom(row.amount_tiyin as number),
                    due: calendarDate(row.due_date as string, timeZone),
                  })}
                </span>
              </p>
            ))}
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('dashboard', 'parentPayments')}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          {payments.length === 0 ? (
            <p className="text-muted-foreground">{t('dashboard', 'parentPaymentsEmpty')}</p>
          ) : (
            payments.map((p) => (
              <p key={p.id} className="flex justify-between gap-2">
                <span className="truncate text-muted-foreground">
                  {dayInZone(p.paid_at, timeZone)} · {label('paymentKind', p.kind)}
                  {p.student_id ? ` · ${childName.get(p.student_id) || ''}` : ''}
                </span>
                <span className={cn('shrink-0 font-medium', p.amount_tiyin < 0 && 'text-destructive')}>{formatSom(p.amount_tiyin)}</span>
              </p>
            ))
          )}
        </CardContent>
      </Card>
    </div>
  )
}
