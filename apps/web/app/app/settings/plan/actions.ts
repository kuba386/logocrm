'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type PlanState = { message?: string; notice?: string }

/**
 * Заявка «я оплатил» — submit_platform_payment (0051): сумма считается в
 * SQL из прайса, вторая открытая заявка отбивается частичным unique,
 * право (owner/admin) и центр — внутри функции. Работает и в режиме только
 * чтения: таблица заявок в списке исключений guard.
 */
export async function submitPayment(_prev: PlanState, formData: FormData): Promise<PlanState> {
  const plan = String(formData.get('plan') ?? '').trim()
  const months = Number(formData.get('months') ?? 0)
  const source = String(formData.get('source') ?? '').trim()
  const note = String(formData.get('note') ?? '').trim()

  if (!plan || !source || !Number.isInteger(months) || months < 1) {
    return { message: t('plan', 'submitFailed') }
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('submit_platform_payment', {
    p_plan: plan,
    p_months: months,
    p_source: source,
    p_note: note || undefined,
  })
  if (error) return toAppError(error, t('plan', 'submitFailed'))

  revalidatePath('/app/settings/plan')
  revalidatePath('/app', 'layout')
  return { notice: t('plan', 'submitted') }
}

/** Отзыв своей открытой заявки — withdraw_platform_payment (0051 Р3). */
export async function withdrawPayment(_prev: PlanState, formData: FormData): Promise<PlanState> {
  const paymentId = String(formData.get('paymentId') ?? '').trim()
  if (!paymentId) return { message: t('plan', 'withdrawFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('withdraw_platform_payment', { p_payment_id: paymentId })
  if (error) return toAppError(error, t('plan', 'withdrawFailed'))

  revalidatePath('/app/settings/plan')
  return { notice: t('plan', 'withdrawn') }
}

export type ExportState = { message?: string; json?: string; filename?: string }

/**
 * Экспорт центра (0056 Р1/Р4/Р11) — по таблице за вызов через
 * export_center_tables()/export_center_table(), не одним jsonb на весь
 * центр разом (упёрлось бы в statement_timeout). Файл собирается здесь,
 * на сервере; клиент только скачивает готовую строку. record_center_export
 * пишет факт выгрузки со счётом строк по каждой таблице.
 */
export async function exportCenterData(_prev: ExportState, _formData: FormData): Promise<ExportState> {
  const supabase = await createClient()

  // Дата в имени файла — из пояса центра (center_today()), не из UTC
  // браузера сервера: иначе вечером в Бишкеке файл называет вчерашним
  // числом сегодняшнюю выгрузку (CLAUDE.md: время в поясе центра).
  const [{ data: center, error: centerError }, { data: tables, error: tablesError }, { data: today }] =
    await Promise.all([
      supabase.rpc('export_center_info'),
      supabase.rpc('export_center_tables'),
      supabase.rpc('center_today', {}),
    ])
  if (centerError) return { message: toAppError(centerError, t('plan', 'exportFailed')).message }
  if (tablesError || !tables) return { message: toAppError(tablesError, t('plan', 'exportFailed')).message }

  const result: Record<string, unknown> = {}
  for (const { table_name } of tables) {
    const { data, error } = await supabase.rpc('export_center_table', { p_table: table_name })
    if (error) return { message: toAppError(error, t('plan', 'exportFailed')).message }
    result[table_name] = data
  }

  // record_center_export() сам пересчитывает строки по таблицам в SQL —
  // не верит числу, которое посчитал бы браузер (0056 Р7).
  await supabase.rpc('record_center_export')

  return {
    json: JSON.stringify({ generated_at: new Date().toISOString(), center, tables: result }, null, 2),
    filename: `logocrm-export-${today ?? new Date().toISOString().slice(0, 10)}.json`,
  }
}

/**
 * audit_log отдельно (0056 Р4) — своя, самая большая таблица у платящего
 * центра; invitations/lesson_voice_requests вычеркнуты в самой RPC (Р2).
 */
export async function exportCenterAudit(_prev: ExportState, formData: FormData): Promise<ExportState> {
  const from = String(formData.get('from') ?? '').trim()
  const to = String(formData.get('to') ?? '').trim()
  if (!from || !to) return { message: t('plan', 'exportFailed') }

  const supabase = await createClient()
  const [{ data, error }, { data: today }] = await Promise.all([
    supabase.rpc('export_center_audit', { p_from: from, p_to: to }),
    supabase.rpc('center_today', {}),
  ])
  if (error) return { message: toAppError(error, t('plan', 'exportFailed')).message }

  return {
    json: JSON.stringify({ from, to, rows: data }, null, 2),
    filename: `logocrm-audit-${today ?? new Date().toISOString().slice(0, 10)}.json`,
  }
}

/** Заявка на удаление центра (0056 Р8) — owner, имя центра как подтверждение. */
export async function requestDeletion(_prev: PlanState, formData: FormData): Promise<PlanState> {
  const confirmName = String(formData.get('confirmName') ?? '').trim()
  if (!confirmName) return { message: t('plan', 'deleteConfirmRequired') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('request_center_deletion', { p_confirm_name: confirmName })
  if (error) return toAppError(error, t('plan', 'deleteFailed'))

  revalidatePath('/app/settings/plan')
  revalidatePath('/app', 'layout')
  return { notice: t('plan', 'deleteRequested') }
}

/** Отмена заявки на удаление (0056 Р9) — owner. */
export async function cancelDeletion(_prev: PlanState, _formData: FormData): Promise<PlanState> {
  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_center_deletion')
  if (error) return toAppError(error, t('plan', 'cancelDeleteFailed'))

  revalidatePath('/app/settings/plan')
  revalidatePath('/app', 'layout')
  return { notice: t('plan', 'deleteCancelled') }
}
