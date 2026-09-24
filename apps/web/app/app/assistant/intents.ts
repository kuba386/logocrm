import 'server-only'
import { formatSom } from '@logocrm/core'
import type { AssistantIntent } from '@logocrm/contracts'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@logocrm/db'
import { t } from '@/lib/messages'
import { statusLabel } from '@/lib/students'
import { addDays, dayInZone, formatInTimeZone, startOfDayInZone, startOfWeek, timeInZone } from '@/lib/timezone'

/**
 * Исполнение намерения — под сессией спросившего (0064, Р3/Р6): те же
 * таблицы под RLS и те же RPC, что у экранов. Провайдер ИИ результата не
 * видит (В1). Отказ по роли уже отбит картой намерений в SQL — здесь пустой
 * ответ означает «данных нет», а не «нет прав».
 */

export type AssistantAnswer = {
  title: string
  columns: string[]
  rows: string[][]
  link?: { href: string; label: string }
}

type Client = SupabaseClient<Database>

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

export async function executeIntent(
  supabase: Client,
  intent: AssistantIntent,
  timeZone: string,
  today: string,
  allowedIntents: string[],
): Promise<AssistantAnswer | null> {
  switch (intent.intent) {
    case 'lessons_on':
      return lessonsOn(supabase, intent.date, timeZone)
    case 'debtors':
      return debtors(supabase, intent.min_som)
    case 'expiring_subscriptions':
      return expiring(supabase, intent.days, intent.lessons_left, timeZone, today)
    case 'student_info':
      // Денежные колонки — только ролям, которым читаемы их источники
      // (student_balance пуст для teacher): пустоту нельзя выдавать за
      // «нет абонемента».
      return studentInfo(supabase, intent.name, timeZone, allowedIntents.includes('expiring_subscriptions'))
    case 'payments_summary':
      return paymentsSummary(supabase, intent.from, intent.to, timeZone)
    case 'unknown':
      return null
  }
}

async function lessonsOn(supabase: Client, date: string, timeZone: string): Promise<AssistantAnswer> {
  // Одним запросом на день в поясе центра, не «T00:00:00Z» (lib/timezone).
  const from = startOfDayInZone(date, timeZone)
  const to = startOfDayInZone(addDays(date, 1), timeZone)
  const { data: rows } = await supabase
    .from('lessons')
    .select('id, starts_at, status, teacher_id, substitute_teacher_id, student_id, group_id')
    .is('deleted_at', null)
    .gte('starts_at', from)
    .lt('starts_at', to)
    .order('starts_at')
  const lessons = rows ?? []
  const teacherIds = [...new Set(lessons.flatMap((l) => [l.teacher_id, l.substitute_teacher_id]).filter((v): v is string => Boolean(v)))]
  const studentIds = [...new Set(lessons.map((l) => l.student_id).filter((v): v is string => Boolean(v)))]
  const groupIds = [...new Set(lessons.map((l) => l.group_id).filter((v): v is string => Boolean(v)))]
  const [{ data: teachers }, { data: students }, { data: groups }] = await Promise.all([
    teacherIds.length ? supabase.from('teachers').select('id, full_name').in('id', teacherIds) : Promise.resolve({ data: [] }),
    studentIds.length ? supabase.from('students').select('id, full_name').in('id', studentIds) : Promise.resolve({ data: [] }),
    groupIds.length ? supabase.from('groups').select('id, name').in('id', groupIds) : Promise.resolve({ data: [] }),
  ])
  const teacherName = new Map((teachers ?? []).map((x) => [x.id, x.full_name]))
  const studentName = new Map((students ?? []).map((x) => [x.id, x.full_name]))
  const groupName = new Map((groups ?? []).map((x) => [x.id, x.name]))

  return {
    title: t('assistant', 'lessonsOn', { date: calendarDate(date, timeZone) }),
    columns: [t('assistant', 'colTime'), t('assistant', 'colWho'), t('assistant', 'colTeacher'), t('assistant', 'colStatus')],
    rows: lessons.map((l) => [
      timeInZone(l.starts_at, timeZone),
      l.group_id ? (groupName.get(l.group_id) ?? 'Группа') : (studentName.get(l.student_id ?? '') ?? 'Занятие'),
      teacherName.get(l.substitute_teacher_id ?? l.teacher_id) ?? '—',
      t('lessonStatus', l.status as 'planned' | 'done' | 'cancelled'),
    ]),
    link: { href: `/app/schedule?week=${startOfWeek(date)}`, label: t('assistant', 'openScreen') },
  }
}

async function debtors(supabase: Client, minSom: number): Promise<AssistantAnswer> {
  const { data: debts } = await supabase.rpc('student_debts')
  const filtered = (debts ?? []).filter((d) => d.debt_tiyin >= minSom * 100).sort((a, b) => b.debt_tiyin - a.debt_tiyin)
  // Имена — из тех же definer-источников, что у экранов роли: у finance нет
  // политик на students/payers (0031), прямой select дал бы прочерки.
  const [{ data: students }, { data: payers }] = await Promise.all([supabase.rpc('students_brief'), supabase.rpc('payers_brief')])
  const studentById = new Map((students ?? []).map((s) => [s.id, s]))
  const payerName = new Map((payers ?? []).map((p) => [p.id, p.full_name]))

  return {
    title: t('assistant', 'debtors', { threshold: minSom > 0 ? t('assistant', 'debtorsThreshold', { som: minSom }) : '' }),
    columns: [t('assistant', 'colStudent'), t('assistant', 'colPayer'), t('assistant', 'colDebtSom')],
    rows: filtered.map((d) => {
      const s = d.student_id ? studentById.get(d.student_id) : undefined
      return [s?.full_name ?? '—', (s?.payer_id && payerName.get(s.payer_id)) || '—', formatSom(d.debt_tiyin)]
    }),
    link: { href: '/app/debts', label: t('assistant', 'openScreen') },
  }
}

async function expiring(supabase: Client, days: number, lessonsLeft: number, timeZone: string, today: string): Promise<AssistantAnswer> {
  const until = addDays(today, days)
  const { data: balances } = await supabase
    .from('student_balance')
    .select('student_id, active_subscription_id, lessons_left, ends_at, state')
    .not('active_subscription_id', 'is', null)
  // Срок — от сегодня: давно истёкшие с непустым active_subscription_id —
  // не «заканчиваются», а уже закончились.
  const hits = (balances ?? []).filter(
    (b) =>
      (b.lessons_left != null && b.lessons_left <= lessonsLeft) || (b.ends_at != null && b.ends_at >= today && b.ends_at <= until),
  )
  const { data: students } = await supabase.rpc('students_brief')
  const name = new Map((students ?? []).map((s) => [s.id, s.full_name]))

  return {
    title: t('assistant', 'expiring', { days, left: lessonsLeft }),
    columns: [t('assistant', 'colStudent'), t('assistant', 'colLessonsLeft'), t('assistant', 'colEndsAt')],
    rows: hits
      .sort((a, b) => (a.ends_at ?? '9999').localeCompare(b.ends_at ?? '9999'))
      .map((b) => [
        name.get(b.student_id ?? '') ?? '—',
        b.state === 'frozen' ? t('assistant', 'frozen') : b.lessons_left == null ? t('assistant', 'unlimited') : String(b.lessons_left),
        b.ends_at ? calendarDate(b.ends_at, timeZone) : '—',
      ]),
    link: { href: '/app/debts?filter=zero', label: t('assistant', 'openScreen') },
  }
}

async function studentInfo(supabase: Client, name: string, timeZone: string, withMoney: boolean): Promise<AssistantAnswer> {
  const { data: found } = await supabase.rpc('global_search', { p_query: name, p_limit: 5 })
  const rows = found ?? []
  const students = rows.filter((r) => r.kind === 'student')
  const lessons = new Map(rows.filter((r) => r.kind === 'lesson').map((r) => [r.title, r]))
  const ids = students.map((s) => s.id)
  const { data: balances } =
    withMoney && ids.length
      ? await supabase.from('student_balance').select('student_id, active_subscription_id, lessons_left, ends_at, debt_tiyin, state').in('student_id', ids)
      : { data: [] }
  const balance = new Map((balances ?? []).map((b) => [b.student_id, b]))

  const moneyColumns = withMoney ? [t('assistant', 'colSubscription'), t('assistant', 'colDebtSom')] : []
  return {
    title: t('assistant', 'studentInfo', { name }),
    columns: [t('assistant', 'colStudent'), ...moneyColumns, t('assistant', 'colNextLesson')],
    rows: students.map((s) => {
      const b = balance.get(s.id)
      // Нет строки — «—», не «нет абонемента»: отсутствие данных ≠ факт.
      const sub = !b
        ? '—'
        : !b.active_subscription_id
          ? t('assistant', 'noSubscription')
          : b.state === 'frozen'
            ? t('assistant', 'frozen')
            : b.lessons_left == null
              ? t('assistant', 'unlimited')
              : `${b.lessons_left}${b.ends_at ? ` · до ${calendarDate(b.ends_at, timeZone)}` : ''}`
      const next = lessons.get(s.title)
      const status = s.status && s.status !== 'active' ? ` (${statusLabel(s.status)})` : ''
      const money = withMoney ? [sub, b?.debt_tiyin ? formatSom(b.debt_tiyin) : '—'] : []
      return [
        `${s.title}${status}`,
        ...money,
        next?.starts_at ? `${dayInZone(next.starts_at, timeZone)}, ${timeInZone(next.starts_at, timeZone)}` : '—',
      ]
    }),
    link: students[0] ? { href: `/app/students/${students[0].id}`, label: t('assistant', 'openScreen') } : undefined,
  }
}

async function paymentsSummary(supabase: Client, from: string, to: string, timeZone: string): Promise<AssistantAnswer> {
  const { data: payments } = await supabase
    .from('payments')
    .select('amount_tiyin, kind')
    .gte('paid_at', startOfDayInZone(from, timeZone))
    .lt('paid_at', startOfDayInZone(addDays(to, 1), timeZone))
  const list = payments ?? []
  const received = list.filter((p) => p.amount_tiyin > 0).reduce((s, p) => s + p.amount_tiyin, 0)
  const refunded = list.filter((p) => p.amount_tiyin < 0).reduce((s, p) => s + p.amount_tiyin, 0)

  return {
    title: t('assistant', 'paymentsSummary', { from: calendarDate(from, timeZone), to: calendarDate(to, timeZone) }),
    columns: [t('assistant', 'colWhat'), t('assistant', 'colSum')],
    rows: [
      [t('assistant', 'received'), formatSom(received)],
      [t('assistant', 'refunded'), formatSom(refunded)],
      [t('assistant', 'paymentsCount'), String(list.length)],
    ],
    link: { href: `/app/finance?month=${from.slice(0, 7)}`, label: t('assistant', 'openScreen') },
  }
}
