import { notFound, redirect } from 'next/navigation'
import { amountInWords, formatSom, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { canPayments } from '@/lib/roles'
import { centerTimeZone, formatInTimeZone } from '@/lib/timezone'
import { label } from '@/lib/messages'
import { ReceiptToolbar } from './receipt-toolbar'

export const metadata = { title: 'Квитанция — LogoCRM' }

/** Номер квитанции — начало id платежа: короткий, однозначный внутри центра, без отдельного счётчика в базе. */
function receiptNumber(id: string): string {
  return id.replace(/-/g, '').slice(0, 8).toUpperCase()
}

/** Возврат на страницу, откуда открыли квитанцию, — только внутренние пути приложения. */
function safeBack(back: string | undefined): string {
  return back && /^\/app(\/[\w\-/]*)?(\?[\w\-=&%]*)?$/.test(back) ? back : '/app/finance'
}

/**
 * Квитанция об оплате — то, что в топовых CRM печатают из платежа (ПКО):
 * центр, номер, дата, плательщик, ребёнок, назначение, способ, сумма цифрами
 * и прописью. Ни одной формулы: строка платежа целиком из базы (RLS payments
 * — те же роли, что принимают оплату), имена — из definer-источников без
 * заметок (payers_brief / students_brief, 0031), сумма прописью — из core.
 */
export default async function ReceiptPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>
  searchParams: Promise<{ back?: string }>
}) {
  const [{ id }, { back }] = await Promise.all([params, searchParams])
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound()

  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!canPayments(role)) redirect('/app')

  const { data: payment } = await supabase
    .from('payments')
    .select('id, payer_id, student_id, subscription_id, amount_tiyin, source_id, paid_at, kind, comment, covers_lesson_debt, voids_payment_id, created_at')
    .eq('id', id)
    .maybeSingle()
  if (!payment) notFound()

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [{ data: center }, { data: payer }, { data: student }, { data: source }, { data: subscription }, { data: voidRow }] =
    await Promise.all([
      supabase.from('centers').select('name, settings').eq('id', centerId).maybeSingle(),
      supabase.rpc('payers_brief').eq('id', payment.payer_id).maybeSingle(),
      payment.student_id
        ? supabase.rpc('students_brief').eq('id', payment.student_id).maybeSingle()
        : Promise.resolve({ data: null }),
      payment.source_id
        ? supabase.from('payment_sources').select('name').eq('id', payment.source_id).maybeSingle()
        : Promise.resolve({ data: null }),
      payment.subscription_id
        ? supabase.from('subscriptions').select('type_id').eq('id', payment.subscription_id).maybeSingle()
        : Promise.resolve({ data: null }),
      // Отменён ли этот платёж (0093): отмена — отдельная строка со ссылкой на исходный.
      supabase.from('payments').select('id, paid_at').eq('voids_payment_id', payment.id).maybeSingle(),
    ])
  const { data: type } = subscription?.type_id
    ? await supabase.from('subscription_types').select('name').eq('id', subscription.type_id).maybeSingle()
    : { data: null }

  const timeZone = centerTimeZone(center?.settings)
  const paidDay = formatInTimeZone(payment.paid_at, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
  const typeName = type?.name ? `«${type.name}»` : ''

  const purpose =
    payment.kind === 'refund'
      ? payment.covers_lesson_debt
        ? 'Возврат аванса за занятия'
        : payment.subscription_id
          ? `Возврат по абонементу ${typeName}`.trim()
          : 'Возврат'
      : payment.kind === 'correction'
        ? payment.voids_payment_id
          ? 'Отмена ошибочного платежа'
          : 'Корректировка'
        : payment.subscription_id
          ? `Оплата абонемента ${typeName}`.trim()
          : payment.covers_lesson_debt
            ? 'Оплата занятий'
            : 'Оплата'
  const refund = payment.amount_tiyin < 0
  const amount = formatSom(Math.abs(payment.amount_tiyin))
  // Заголовок — по виду операции, а не по знаку: отмена ошибочного платежа —
  // отрицательная корректировка, но это не «возврат» семье (0093).
  const heading =
    payment.kind === 'payment'
      ? 'Квитанция об оплате'
      : payment.kind === 'refund'
        ? 'Квитанция о возврате'
        : payment.voids_payment_id
          ? 'Отмена ошибочного платежа'
          : 'Корректировка'
  const number = receiptNumber(payment.id)

  const wa = whatsappNumber(payer?.phone ?? null)
  const message = [
    `${center?.name ?? 'Центр'}: квитанция № ${number}`,
    `${payment.kind === 'payment' ? 'Получено' : payment.kind === 'refund' ? 'Возврат' : 'Корректировка'}: ${refund ? '−' : ''}${amount}${source?.name ? ` (${source.name})` : ''}, ${paidDay}`,
    student?.full_name ? `Ученик: ${student.full_name}` : null,
    `Назначение: ${purpose}`,
    'Спасибо!',
  ]
    .filter(Boolean)
    .join('\n')

  return (
    <div className="space-y-6">
      <ReceiptToolbar backHref={safeBack(back)} whatsappHref={wa ? `https://wa.me/${wa}?text=${encodeURIComponent(message)}` : null} />

      <article className="mx-auto max-w-lg space-y-6 rounded-xl border border-border bg-card p-6 text-card-foreground print:max-w-none print:border-0 print:p-0">
        <header className="space-y-1 border-b border-border pb-4">
          <p className="text-sm text-muted-foreground">{center?.name ?? 'LogoCRM'}</p>
          <h1 className="font-display text-xl font-medium">
            {heading} № {number}
          </h1>
          <p className="text-sm text-muted-foreground">от {paidDay}</p>
        </header>

        {voidRow ? (
          <p role="note" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
            Платёж отменён как ошибочный{voidRow.paid_at ? ` (${formatInTimeZone(voidRow.paid_at, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })})` : ''} —
            квитанция недействительна.
          </p>
        ) : null}

        <dl className="grid grid-cols-[minmax(7rem,auto)_1fr] gap-x-4 gap-y-3 text-sm">
          <dt className="text-muted-foreground">Плательщик</dt>
          <dd className="font-medium">{payer?.full_name ?? '—'}</dd>
          {student?.full_name ? (
            <>
              <dt className="text-muted-foreground">Ученик</dt>
              <dd className="font-medium">{student.full_name}</dd>
            </>
          ) : null}
          <dt className="text-muted-foreground">Назначение</dt>
          <dd>{purpose}</dd>
          <dt className="text-muted-foreground">Вид</dt>
          <dd>{label('paymentKind', payment.kind)}</dd>
          <dt className="text-muted-foreground">Способ оплаты</dt>
          <dd>{source?.name ?? 'не указан'}</dd>
          {payment.comment && payment.comment !== purpose ? (
            <>
              <dt className="text-muted-foreground">Комментарий</dt>
              <dd className="whitespace-pre-line">{payment.comment}</dd>
            </>
          ) : null}
        </dl>

        <div className="space-y-1 rounded-lg bg-muted/60 p-4 print:bg-transparent print:p-0">
          <p className="text-sm text-muted-foreground">{payment.kind === 'refund' ? 'Сумма возврата' : 'Сумма'}</p>
          <p className="font-display text-3xl font-medium tabular-nums">{amount}</p>
          <p className="text-sm">{amountInWords(Math.abs(payment.amount_tiyin))}</p>
        </div>

        <footer className="grid gap-6 pt-2 text-sm sm:grid-cols-2">
          <p>
            {payment.kind === 'refund' ? 'Выдал' : 'Принял'}: ____________________
          </p>
          <p>Плательщик: ____________________</p>
          <p className="text-xs text-muted-foreground sm:col-span-2">
            Оформлено в LogoCRM {formatInTimeZone(payment.created_at, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })}
          </p>
        </footer>
      </article>
    </div>
  )
}
