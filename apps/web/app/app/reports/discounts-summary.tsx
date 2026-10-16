import { formatSom } from '@logocrm/core'
import type { createClient } from '@/lib/supabase/server'
import { t } from '@/lib/messages'
import { monthBounds } from '@/lib/month'
import { formatInTimeZone, monthLabel } from '@/lib/timezone'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { FormError } from '@/components/ui/alert'
import { loadErrorMessage } from '@/lib/errors'
import { roleLabel } from '@/lib/roles'

type Supabase = Awaited<ReturnType<typeof createClient>>

/** Последний день месяца: отчёт берёт период включительно, как выгрузки 0058. */
function lastDay(next: string): string {
  const d = new Date(`${next}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() - 1)
  return d.toISOString().slice(0, 10)
}

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit' })
}

/**
 * Скидки за месяц (0101): сколько недополучено против цены типа, по причинам и
 * по продажам, с автором продажи — контроль скидок, как в топовых CRM. Суммы и
 * группировка — из базы (subscription_discount_totals), здесь только подписи.
 * Кто продал: имя карточки специалиста и роль — из отчёта (бухгалтеру
 * staff_view отдаёт только его строку); владельцу и админу staff_view
 * добавляет email сотрудника без карточки.
 */
export async function DiscountsSummary({ supabase, month, timeZone }: { supabase: Supabase; month: string; timeZone: string }) {
  const { first, next } = monthBounds(month)
  const to = lastDay(next)
  const [{ data: totals, error: totalsError }, { data: rows, error: rowsError }, { data: staff }] = await Promise.all([
    supabase.rpc('subscription_discount_totals', { p_from: first, p_to: to }),
    supabase.rpc('subscription_discounts', { p_from: first, p_to: to }),
    supabase.from('staff_view').select('user_id, full_name, email'),
  ])
  const error = totalsError ?? rowsError
  const staffName = new Map((staff ?? []).map((m) => [m.user_id, m.full_name ?? m.email ?? null]))
  const seller = (r: { sold_by: string | null; sold_by_name: string | null; sold_by_role: string | null }) =>
    r.sold_by_name ?? (r.sold_by ? staffName.get(r.sold_by) : null) ?? (r.sold_by_role ? roleLabel(r.sold_by_role) : '—')
  const total = (totals ?? []).find((r) => r.is_total)
  const byReason = (totals ?? []).filter((r) => !r.is_total)

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('reports', 'discountsTitle', { month: monthLabel(first) })}</CardTitle>
        <CardDescription>{t('reports', 'discountsHint')}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {error ? (
          <FormError message={loadErrorMessage(error, t('reports', 'discountsLoadFailed'))} />
        ) : !total || total.sales === 0 ? (
          <p className="text-sm text-muted-foreground">{t('reports', 'discountsEmpty')}</p>
        ) : (
          <>
            <p className="text-sm">
              {t('reports', 'discountsTotal', { sum: formatSom(Number(total.discount_tiyin)), count: total.sales })}
            </p>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('reports', 'discountsReason')}</TableHead>
                  <TableHead className="text-right">{t('reports', 'discountsSales')}</TableHead>
                  <TableHead className="text-right">{t('reports', 'discountsAmount')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {byReason.map((r) => (
                  <TableRow key={r.reason_id ?? 'none'}>
                    <TableCell>{r.reason_name ?? t('reports', 'discountsNoReason')}</TableCell>
                    <TableCell className="text-right tabular-nums text-muted-foreground">{r.sales}</TableCell>
                    <TableCell className="text-right tabular-nums">{formatSom(Number(r.discount_tiyin))}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            <details className="text-sm">
              <summary className="cursor-pointer font-medium">{t('reports', 'discountsDetails', { count: (rows ?? []).length })}</summary>
              <Table className="mt-2 max-sm:[&_tr>*:nth-child(3)]:hidden max-sm:[&_tr>*:nth-child(6)]:hidden">
                <TableHeader>
                  <TableRow>
                    <TableHead>{t('reports', 'discountsDate')}</TableHead>
                    <TableHead>{t('reports', 'discountsStudent')}</TableHead>
                    <TableHead>{t('reports', 'discountsType')}</TableHead>
                    <TableHead className="text-right">{t('reports', 'discountsPrice')}</TableHead>
                    <TableHead className="text-right">{t('reports', 'discountsAmount')}</TableHead>
                    <TableHead>{t('reports', 'discountsSeller')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(rows ?? []).map((r) => (
                    <TableRow key={r.subscription_id}>
                      <TableCell className="whitespace-nowrap">{calendarDate(r.sold_on, timeZone)}</TableCell>
                      <TableCell>
                        {r.student_name ?? '—'}
                        <span className="block text-xs text-muted-foreground">{r.reason_name ?? t('reports', 'discountsNoReason')}</span>
                      </TableCell>
                      <TableCell className="text-muted-foreground">{r.type_name ?? '—'}</TableCell>
                      <TableCell className="whitespace-nowrap text-right tabular-nums">
                        <span className="text-muted-foreground line-through">{formatSom(r.list_price_tiyin)}</span> {formatSom(r.price_tiyin)}
                      </TableCell>
                      <TableCell className="text-right font-medium tabular-nums">{formatSom(r.discount_tiyin)}</TableCell>
                      <TableCell className="text-muted-foreground">{seller(r)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </details>
          </>
        )}
      </CardContent>
    </Card>
  )
}
