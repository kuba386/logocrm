import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { statusLabel, studentAge } from '@/lib/students'
import { isFrontDesk } from '@/lib/roles'
import type { DebtProblem } from '@/lib/debts'
import { label, t } from '@/lib/messages'
import { calendarDay, centerTimeZone, dayInZone } from '@/lib/timezone'
import { PageHeader } from '@/components/ui/page-header'
import { FormError } from '@/components/ui/alert'
import { loadErrorMessage } from '@/lib/errors'
import { StatusBadge } from '@/components/ui/status-badge'
import { AddStudentDialog } from '@/app/app/students/add-student-dialog'
import { PayerTelegramPanel, type PayerTelegramStatus } from './payer-telegram-panel'
import { DebtActions } from '@/app/app/debts/debt-dialogs'
import { PageNoticeProvider } from '@/components/ui/page-notice'
import { receiptHref } from '@/lib/receipt'
import { isoDayInZone } from '@/lib/timezone'

export const metadata = { title: 'Плательщик — LogoCRM' }

export default async function PayerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Гейт — RLS, не роль в коде (0062): карточку читают те, кому payers
  // читаемы (owner/admin, registrar, родитель — свою); остальным строка не
  // придёт → notFound. Иначе поиск отдавал бы строки, которые нельзя открыть.
  const { data: role } = await supabase.rpc('my_role')
  const frontDesk = isFrontDesk(role)

  const { data: payer } = await supabase
    .from('payers')
    .select('id, full_name, phone, phone_alt, email, relation, notes')
    .eq('id', id)
    .is('deleted_at', null)
    .maybeSingle()

  if (!payer) notFound()

  // Бейдж — узкой функцией, а не чтением telegram_accounts: таблица привязок
  // стойке не положена, ответ нужен один — «да/нет» (0033).
  const [{ data: children }, { data: teachers }, { data: telegramLinked }, { data: telegramStatus }] = await Promise.all([
    supabase
      .from('students')
      .select('id, full_name, birth_date, status')
      .eq('payer_id', id)
      .is('deleted_at', null)
      .order('full_name'),
    supabase
      .from('teachers')
      .select('id, full_name')
      .is('deleted_at', null)
      .eq('is_active', true)
      .order('full_name'),
    // Бейдж и действия стойки — только стойке; родитель видит свою карточку
    // без кнопок (RLS пустила бы его к строке, а RPC отказал бы).
    frontDesk ? supabase.rpc('payer_telegram_linked', { p_payer_id: id }) : Promise.resolve({ data: null }),
    // Кто подключён и живая ссылка (0098) — без кода: он показывается один раз.
    frontDesk ? supabase.rpc('payer_telegram_status', { p_payer_id: id }) : Promise.resolve({ data: null }),
  ])

  // Долги — тем же единым источником, что /app/debts и дашборд (0076): права
  // по роли внутри функции, здесь только отбор строк этого плательщика.
  // overdue_payer_id — плательщик просроченного АБОНЕМЕНТА, он может не
  // совпадать с текущим payer_id ребёнка (0060, 0070).
  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [
    { data: debtRows },
    { data: payments },
    { data: center },
    { data: installmentRows },
    { data: sourceRows },
    { data: summaryRows, error: summaryError },
  ] = await Promise.all([
    supabase.rpc('student_debt_problems'),
    supabase
      .from('payments')
      .select('id, amount_tiyin, paid_at, kind, student_id, comment, voids_payment_id')
      .eq('payer_id', id)
      .order('paid_at', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(10),
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    // Неоплаченные платежи рассрочки, где плательщик — этот человек: он и
    // будет платить, стойке это нужно видеть до звонка. Состояние считает
    // installments_view (0020), не браузер.
    supabase
      .from('installments_view')
      .select('id, student_id, due_date, amount_tiyin, row_remaining_tiyin, state')
      .eq('payer_id', id)
      .is('cancelled_at', null)
      .neq('state', 'paid')
      .order('due_date'),
    // Источники — для «Принять оплату долга» прямо на карточке семьи.
    frontDesk
      ? supabase.from('payment_sources').select('id, name').eq('is_active', true).is('deleted_at', null).order('sort')
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    // Деньги семьи (0100): строка на ребёнка и итог — суммы считает база, не
    // reduce здесь. Долг за занятия и аванс — детей этого плательщика сейчас,
    // просрочка и недоплата — абонементов, которые он покупал.
    supabase.rpc('payer_money_summary', { p_payer_id: id }),
  ])
  const timeZone = centerTimeZone(center?.settings)
  const today = isoDayInZone(new Date(), timeZone)
  const sources = (sourceRows ?? []).map((src) => ({ id: src.id, name: src.name }))
  const installments = (installmentRows ?? []).filter((r) => r.due_date && r.row_remaining_tiyin != null)
  const myDebtRows = (debtRows ?? []).filter((r) => r.payer_id === id || r.overdue_payer_id === id)
  // Генератор типов объявляет колонки table-функции non-null, в рантайме бывают NULL.
  const familyTotal = (summaryRows ?? []).find((r) => (r.student_id as string | null) === null) ?? null
  const moneyByStudent = new Map((summaryRows ?? []).filter((r) => r.student_id).map((r) => [r.student_id, r]))
  // Долг за занятия по ребёнку — для кнопки оплаты (payer_money_summary, 0100).
  const lessonDebtByStudent = new Map([...moneyByStudent].map(([sid, r]) => [sid, Number(r.lesson_debt_tiyin)]))
  // «Остаток исчерпан» — не деньги, сигнал «пора продлить» (0076): только когда денежных проблем нет.
  const zeroLeft = new Set(myDebtRows.filter((r) => r.zero_left).map((r) => r.student_id))
  const debtByStudent = new Map(
    (children ?? []).map((c) => {
      const m = moneyByStudent.get(c.id)
      const list: DebtProblem[] = []
      if (m && Number(m.lesson_debt_tiyin) > 0) list.push({ label: 'Долг за занятия', amount: Number(m.lesson_debt_tiyin), tone: 'danger' })
      if (m && Number(m.overdue_tiyin) > 0) list.push({ label: 'Просрочен платёж за абонемент', amount: Number(m.overdue_tiyin), tone: 'danger' })
      if (list.length === 0 && zeroLeft.has(c.id)) list.push({ label: 'Остаток исчерпан', amount: null, tone: 'warning' })
      return [c.id, list] as const
    }),
  )
  const creditByStudent = new Map([...moneyByStudent].map(([sid, r]) => [sid, Number(r.credit_tiyin)]))
  const childIds = new Set((children ?? []).map((c) => c.id))
  // Абонемент покупал этот плательщик, а ребёнок сейчас записан на другого (0060, 0070).
  const otherDebtRows = [...moneyByStudent.values()]
    .filter((r) => !childIds.has(r.student_id) && Number(r.overdue_tiyin) > 0)
    .map((r) => ({
      student_id: r.student_id,
      // Имя — из всего списка проблем, а не из отобранных по плательщику: у ребёнка с
      // просрочкой двух плательщиков overdue_payer_id = NULL, и в отбор он не попадает.
      full_name: (debtRows ?? []).find((d) => d.student_id === r.student_id)?.full_name ?? 'Ребёнок',
      overdue_tiyin: Number(r.overdue_tiyin),
    }))
  const studentNames = new Map<string, string>([
    ...(children ?? []).map((c) => [c.id, c.full_name] as [string, string]),
    ...myDebtRows.map((r) => [r.student_id, r.full_name] as [string, string]),
  ])

  const wa = whatsappNumber(payer.phone)

  return (
    <div className="space-y-6">
      <PageHeader
        back={frontDesk ? { href: '/app/payers', label: 'Все плательщики' } : undefined}
        title={payer.full_name}
        aside={
          frontDesk ? (
            <StatusBadge tone={telegramLinked ? 'success' : 'neutral'}>
              {telegramLinked ? 'Telegram привязан' : 'Telegram не привязан'}
            </StatusBadge>
          ) : null
        }
        description={[payer.relation ?? 'родитель', formatKgPhone(payer.phone), payer.email].filter(Boolean).join(', ')}
        actions={
          frontDesk ? (
            <>
              <a href={`tel:${payer.phone}`} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                Позвонить
              </a>
              {wa ? (
                <a
                  href={`https://wa.me/${wa}`}
                  target="_blank"
                  rel="noreferrer"
                  className={buttonVariants({ variant: 'outline', size: 'sm' })}
                >
                  WhatsApp
                </a>
              ) : null}
              <AddStudentDialog
                teachers={(teachers ?? []).map((t) => ({ id: t.id, fullName: t.full_name }))}
                presetPayer={{ id: payer.id, fullName: payer.full_name }}
                label="Добавить ребёнка"
              />
            </>
          ) : null
        }
      />

      {frontDesk && telegramStatus ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('payerTelegram', 'title')}</CardTitle>
            <CardDescription>{t('payerTelegram', 'description')}</CardDescription>
          </CardHeader>
          <CardContent>
            <PayerTelegramPanel
              payerId={payer.id}
              whatsapp={wa}
              status={telegramStatus as unknown as PayerTelegramStatus}
              canManage={role === 'owner' || role === 'admin'}
              timeZone={timeZone}
            />
          </CardContent>
        </Card>
      ) : null}

      {/* Деньги семьи (0100): три разных долга не складываются (Database.md) — раздельно. */}
      {summaryError ? (
        <FormError message={loadErrorMessage(summaryError, 'Не удалось посчитать деньги семьи. Обновите страницу.')} />
      ) : familyTotal ? (
        <FamilyMoney total={familyTotal} />
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Дети</CardTitle>
          <CardDescription>Все, за кого платит этот человек.</CardDescription>
        </CardHeader>
        <CardContent>
          <PageNoticeProvider>
          {children && children.length > 0 ? (
            <ul className="space-y-2">
              {children.map((child) => (
                <li
                  key={child.id}
                  className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-md border border-border p-3"
                >
                  <div>
                    <Link href={`/app/students/${child.id}`} className="font-medium hover:underline">
                      {child.full_name}
                    </Link>
                    <p className="text-sm text-muted-foreground">
                      {studentAge(child.birth_date)}, {statusLabel(child.status).toLowerCase()}
                    </p>
                  </div>
                  <div className="flex flex-wrap items-center gap-1.5">
                    {(debtByStudent.get(child.id) ?? []).map((problem) => (
                      <StatusBadge key={problem.label} tone={problem.tone}>
                        {problem.label}
                        {problem.amount != null ? ` ${formatSom(problem.amount)}` : ''}
                      </StatusBadge>
                    ))}
                    {(creditByStudent.get(child.id) ?? 0) > 0 ? (
                      <StatusBadge tone="success">Аванс {formatSom(creditByStudent.get(child.id) ?? 0)}</StatusBadge>
                    ) : null}
                    {/* Оплата долга за занятия — прямо на карточке семьи (0087), без похода в «Долги». */}
                    {frontDesk && (lessonDebtByStudent.get(child.id) ?? 0) > 0 ? (
                      <DebtActions
                        studentId={child.id}
                        studentName={child.full_name}
                        remainingTiyin={lessonDebtByStudent.get(child.id) ?? 0}
                        sources={sources}
                        today={today}
                        canWriteOff={role === 'owner'}
                        back={`/app/payers/${payer.id}`}
                      />
                    ) : null}
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">Детей пока нет.</p>
          )}
          </PageNoticeProvider>
        </CardContent>
      </Card>

      {otherDebtRows.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Просроченные абонементы других детей</CardTitle>
            <CardDescription>Абонемент покупал этот плательщик, а ребёнок сейчас записан на другого.</CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="space-y-2 text-sm">
              {otherDebtRows.map((r) => (
                <li key={r.student_id} className="flex flex-wrap items-center justify-between gap-2">
                  {/* Родитель карточку чужого теперь ребёнка не откроет — ссылка только стойке. */}
                  {frontDesk ? (
                    <Link href={`/app/students/${r.student_id}#subscriptions`} className="font-medium hover:underline">
                      {r.full_name}
                    </Link>
                  ) : (
                    <span className="font-medium">{r.full_name}</span>
                  )}
                  <StatusBadge tone="danger">Просрочен платёж за абонемент {formatSom(r.overdue_tiyin)}</StatusBadge>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      ) : null}

      {installments.length > 0 ? (
        <Card>
          <CardHeader>
            <CardTitle>Ближайшие платежи по рассрочке</CardTitle>
            <CardDescription>Принять платёж — в «Финансы» → «Рассрочки».</CardDescription>
          </CardHeader>
          <CardContent>
            <ul className="divide-y divide-border text-sm">
              {installments.map((row) => (
                <li key={row.id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-2">
                  <span>
                    <span className="tabular-nums text-muted-foreground">
                      {calendarDay(row.due_date as string, { day: 'numeric', month: 'long', year: 'numeric' })}
                    </span>
                    {row.student_id && studentNames.get(row.student_id) ? ` — ${studentNames.get(row.student_id)}` : ''}
                  </span>
                  <span className="flex items-center gap-2">
                    <StatusBadge tone={row.state === 'overdue' ? 'danger' : row.state === 'due' ? 'warning' : 'neutral'}>
                      {label('installmentState', row.state ?? '')}
                    </StatusBadge>
                    {/* Остаток строки (0100) — как в сводке семьи выше, не плановая сумма. */}
                    <span className="font-medium tabular-nums">{formatSom(row.row_remaining_tiyin as number)}</span>
                  </span>
                </li>
              ))}
            </ul>
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Платежи</CardTitle>
          <CardDescription>{frontDesk ? 'Последние десять. Все платежи — в разделе «Финансы».' : 'Последние десять.'}</CardDescription>
        </CardHeader>
        <CardContent>
          {payments && payments.length > 0 ? (
            <ul className="divide-y divide-border text-sm">
              {payments.map((p) => (
                <li key={p.id} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-2">
                  <span>
                    <span className="tabular-nums text-muted-foreground">{dayInZone(p.paid_at, timeZone)}</span>
                    {' — '}
                    {label('paymentKind', p.kind)}
                    {p.student_id && studentNames.get(p.student_id) ? `, ${studentNames.get(p.student_id)}` : ''}
                    {(payments ?? []).some((v) => v.voids_payment_id === p.id) ? (
                      <span className="block text-xs text-destructive">отменён</span>
                    ) : null}
                    {p.comment ? <span className="block text-xs text-muted-foreground">{p.comment}</span> : null}
                  </span>
                  <span className="flex items-center gap-2">
                    <span className="font-medium tabular-nums">{formatSom(p.amount_tiyin)}</span>
                    {frontDesk ? (
                      <Link href={receiptHref(p.id, `/app/payers/${payer.id}`)} className="text-xs text-primary underline-offset-4 hover:underline">
                        Квитанция
                      </Link>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">Платежей пока нет.</p>
          )}
        </CardContent>
      </Card>

      {/* Заметка стойки о родителе — не родителю. */}
      {frontDesk && payer.notes ? (
        <Card>
          <CardHeader>
            <CardTitle>Заметка</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="whitespace-pre-line text-sm">{payer.notes}</p>
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}

type MoneyRow = {
  lesson_debt_tiyin: number
  credit_tiyin: number
  overdue_tiyin: number
  unpaid_tiyin: number
  next_due_date: string | null
  next_due_tiyin: number | null
}

/**
 * Сводка денег семьи — одна строка цифр, как «баланс клиента» в топовых CRM,
 * но без сложения разных долгов: долг за занятия, просрочка по абонементам и
 * «не доплачено всего» — разные вопросы (docs/Database.md, «Два слова…»).
 */
function FamilyMoney({ total }: { total: MoneyRow }) {
  const lessonDebt = Number(total.lesson_debt_tiyin)
  const overdue = Number(total.overdue_tiyin)
  const unpaid = Number(total.unpaid_tiyin)
  const credit = Number(total.credit_tiyin)
  const nextDue = total.next_due_date
  const clear = lessonDebt === 0 && overdue === 0 && unpaid === 0 && credit === 0 && !nextDue
  return (
    <Card>
      <CardHeader>
        <CardTitle>Деньги семьи</CardTitle>
        <CardDescription>{clear ? 'Долгов и авансов нет.' : 'Считает база: по всем детям этого плательщика и его абонементам.'}</CardDescription>
      </CardHeader>
      {clear ? null : (
        <CardContent>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-5">
            <div>
              <dt className="text-xs text-muted-foreground">Долг за занятия</dt>
              <dd className={lessonDebt > 0 ? 'font-medium text-destructive' : 'font-medium'}>{lessonDebt > 0 ? formatSom(lessonDebt) : 'нет'}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Просрочка по абонементам</dt>
              <dd className={overdue > 0 ? 'font-medium text-destructive' : 'font-medium'}>{overdue > 0 ? formatSom(overdue) : 'нет'}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Не доплачено всего</dt>
              <dd className="font-medium">{unpaid > 0 ? formatSom(unpaid) : 'нет'}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Аванс</dt>
              <dd className={credit > 0 ? 'font-medium text-success' : 'font-medium'}>{credit > 0 ? formatSom(credit) : 'нет'}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted-foreground">Ближайший платёж</dt>
              <dd className="font-medium">
                {nextDue
                  ? `${calendarDay(nextDue, { day: 'numeric', month: 'long' })} · ${formatSom(Number(total.next_due_tiyin ?? 0))}`
                  : 'нет'}
              </dd>
            </div>
          </dl>
        </CardContent>
      )}
    </Card>
  )
}
