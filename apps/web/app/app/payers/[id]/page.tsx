import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { statusLabel, studentAge } from '@/lib/students'
import { isFrontDesk } from '@/lib/roles'
import { debtProblems } from '@/lib/debts'
import { label } from '@/lib/messages'
import { calendarDay, centerTimeZone, dayInZone } from '@/lib/timezone'
import { PageHeader } from '@/components/ui/page-header'
import { StatusBadge } from '@/components/ui/status-badge'
import { AddStudentDialog } from '@/app/app/students/add-student-dialog'

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
  const [{ data: children }, { data: teachers }, { data: telegramLinked }] = await Promise.all([
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
  ])

  // Долги — тем же единым источником, что /app/debts и дашборд (0076): права
  // по роли внутри функции, здесь только отбор строк этого плательщика.
  // overdue_payer_id — плательщик просроченного АБОНЕМЕНТА, он может не
  // совпадать с текущим payer_id ребёнка (0060, 0070).
  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [{ data: debtRows }, { data: payments }, { data: center }, { data: installmentRows }] = await Promise.all([
    supabase.rpc('student_debt_problems'),
    supabase
      .from('payments')
      .select('id, amount_tiyin, paid_at, kind, student_id, comment')
      .eq('payer_id', id)
      .order('paid_at', { ascending: false })
      .limit(10),
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    // Неоплаченные платежи рассрочки, где плательщик — этот человек: он и
    // будет платить, стойке это нужно видеть до звонка. Состояние считает
    // installments_view (0020), не браузер.
    supabase
      .from('installments_view')
      .select('id, student_id, due_date, amount_tiyin, state')
      .eq('payer_id', id)
      .is('cancelled_at', null)
      .neq('state', 'paid')
      .order('due_date'),
  ])
  const timeZone = centerTimeZone(center?.settings)
  const installments = (installmentRows ?? []).filter((r) => r.due_date && r.amount_tiyin != null)
  const myDebtRows = (debtRows ?? []).filter((r) => r.payer_id === id || r.overdue_payer_id === id)
  const debtByStudent = new Map(
    myDebtRows.map((r) => [
      r.student_id,
      debtProblems({
        debtTiyin: r.payer_id === id ? r.debt_tiyin : 0,
        overdrawnTiyin: r.payer_id === id ? r.overdrawn_tiyin : 0,
        subscriptionOverdueTiyin: r.overdue_payer_id === id ? r.overdue_tiyin : 0,
      }),
    ]),
  )
  const childIds = new Set((children ?? []).map((c) => c.id))
  const otherDebtRows = myDebtRows.filter((r) => !childIds.has(r.student_id) && r.overdue_payer_id === id && r.overdue_tiyin > 0)
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
              {!telegramLinked && wa ? (
                <a
                  href={`https://wa.me/${wa}?text=${encodeURIComponent(
                    'Здравствуйте! Чтобы получать напоминания о занятиях и остаток абонемента, привяжите Telegram: откройте LogoCRM → раздел Telegram → «Получить код».',
                  )}`}
                  target="_blank"
                  rel="noreferrer"
                  className={buttonVariants({ variant: 'outline', size: 'sm' })}
                >
                  Пригласить в бот
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

      <Card>
        <CardHeader>
          <CardTitle>Дети</CardTitle>
          <CardDescription>Все, за кого платит этот человек.</CardDescription>
        </CardHeader>
        <CardContent>
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
                  <div className="flex flex-wrap gap-1.5">
                    {(debtByStudent.get(child.id) ?? []).map((problem) => (
                      <StatusBadge key={problem.label} tone={problem.tone}>
                        {problem.label}
                        {problem.amount != null ? ` ${formatSom(problem.amount)}` : ''}
                      </StatusBadge>
                    ))}
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">Детей пока нет.</p>
          )}
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
                  <Link href={`/app/students/${r.student_id}#subscriptions`} className="font-medium hover:underline">
                    {r.full_name}
                  </Link>
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
                    <span className="font-medium tabular-nums">{formatSom(row.amount_tiyin as number)}</span>
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
                    {p.comment ? <span className="block text-xs text-muted-foreground">{p.comment}</span> : null}
                  </span>
                  <span className="font-medium tabular-nums">{formatSom(p.amount_tiyin)}</span>
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
