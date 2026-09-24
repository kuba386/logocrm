'use server'

import { exportReportRequestSchema } from '@logocrm/contracts'
import { csvDate, csvMoney, toCsv, type CsvCell } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { label, t } from '@/lib/messages'

export type ExportState = { message?: string; csv?: string; filename?: string }

/**
 * Выгрузка отчёта в CSV (0058). Строки и след (report.exported) — в SQL,
 * здесь только сборка файла и имя. Доставка — как у экспорта центра (0056):
 * server action отдаёт строку, клиент скачивает Blob; так ошибка приходит
 * через toAppError на экран, а протухшая сессия не превращается в CSV с
 * HTML страницы входа внутри (Architect-ревью 0058, Р9).
 *
 * Роль проверяет SQL: кнопки на экране повторяют тот же предикат, но отказ
 * приходит из базы (CLAUDE.md).
 */
export async function exportReport(_prev: ExportState, formData: FormData): Promise<ExportState> {
  const raw = {
    report: String(formData.get('report') ?? ''),
    from: formData.get('from') ? String(formData.get('from')) : undefined,
    to: formData.get('to') ? String(formData.get('to')) : undefined,
    // <input type="month"> отдаёт ГГГГ-ММ — доводим до первого числа.
    month: formData.get('month') ? `${String(formData.get('month')).slice(0, 7)}-01` : undefined,
  }
  const parsed = exportReportRequestSchema.safeParse(raw)
  if (!parsed.success) return { message: t('reports', 'periodInvalid') }

  const supabase = await createClient()
  // Дата в имени файла — от пояса центра (center_today()), не от UTC
  // сервера: вечером в Бишкеке файл иначе называл бы вчерашним числом.
  const { data: today } = await supabase.rpc('center_today', {})
  const stamp = today ?? new Date().toISOString().slice(0, 10)
  const req = parsed.data

  switch (req.report) {
    case 'payments': {
      const { data, error } = await supabase.rpc('export_payments', { p_from: req.from, p_to: req.to })
      if (error) return { message: toAppError(error, t('reports', 'failed')).message }
      const headers = [
        t('reports', 'colDate'), t('reports', 'colTime'), t('reports', 'colKind'), t('reports', 'colAmountSom'),
        t('reports', 'colPayer'), t('reports', 'colPhone'), t('reports', 'colStudent'),
        t('reports', 'colSubscriptionType'), t('reports', 'colSource'), t('reports', 'colComment'),
      ]
      const rows: CsvCell[][] = (data ?? []).map((r) => [
        csvDate(r.paid_on), r.paid_time, label('paymentKind', r.kind), csvMoney(r.amount_tiyin),
        r.payer_name, r.payer_phone, r.student_name, r.subscription_type, r.source_name, r.comment,
      ])
      return { csv: toCsv(headers, rows), filename: `logocrm-payments-${req.from}_${req.to}.csv` }
    }
    case 'salary_summary': {
      const { data, error } = await supabase.rpc('export_salary_summary', { p_month: req.month })
      if (error) return { message: toAppError(error, t('reports', 'failed')).message }
      const headers = [
        t('reports', 'colTeacher'), t('reports', 'colCalcSom'), t('reports', 'colAdjustmentsSom'),
        t('reports', 'colTotalSom'), t('reports', 'colApproved'), t('reports', 'colApprovedAt'),
      ]
      const rows: CsvCell[][] = (data ?? []).map((r) => [
        r.teacher_name, csvMoney(r.calc_tiyin), csvMoney(r.adjustments_tiyin), csvMoney(r.total_tiyin),
        r.approved, csvDate(r.approved_at),
      ])
      return { csv: toCsv(headers, rows), filename: `logocrm-salary-summary-${req.month.slice(0, 7)}.csv` }
    }
    case 'salary_details': {
      const { data, error } = await supabase.rpc('export_salary_details', { p_month: req.month })
      if (error) return { message: toAppError(error, t('reports', 'failed')).message }
      const headers = [
        t('reports', 'colTeacher'), t('reports', 'colDate'), t('reports', 'colStudent'), t('reports', 'colModel'),
        t('reports', 'colLessonPriceSom'), t('reports', 'colAccruedSom'), t('reports', 'colNote'), t('reports', 'colApproved'),
      ]
      const rows: CsvCell[][] = (data ?? []).map((r) => [
        r.teacher_name, csvDate(r.lesson_date), r.student_name,
        r.model ? label('salary', `model_${r.model}`) : '',
        csvMoney(r.lesson_price_tiyin), csvMoney(r.amount_tiyin), r.note, r.approved,
      ])
      return { csv: toCsv(headers, rows), filename: `logocrm-salary-details-${req.month.slice(0, 7)}.csv` }
    }
    case 'attendance': {
      const { data, error } = await supabase.rpc('export_attendance', { p_from: req.from, p_to: req.to })
      if (error) return { message: toAppError(error, t('reports', 'failed')).message }
      const headers = [
        t('reports', 'colDate'), t('reports', 'colTime'), t('reports', 'colLessonStatus'), t('reports', 'colTeacher'),
        t('reports', 'colPaidTeacher'), t('reports', 'colStudent'), t('reports', 'colService'), t('reports', 'colGroup'),
        t('reports', 'colAttendanceStatus'), t('reports', 'colIsPresent'), t('reports', 'colDeducted'),
        t('reports', 'colPaysTeacher'), t('reports', 'colPriceSom'),
      ]
      const rows: CsvCell[][] = (data ?? []).map((r) => [
        csvDate(r.lesson_date), r.lesson_time, label('lessonStatus', r.lesson_status), r.teacher_name,
        r.paid_teacher_name, r.student_name, r.service_name, r.group_name, r.status_name,
        r.is_present, r.deducted, r.pays_teacher, csvMoney(r.price_tiyin),
      ])
      return { csv: toCsv(headers, rows), filename: `logocrm-attendance-${req.from}_${req.to}.csv` }
    }
    case 'debts': {
      const { data, error } = await supabase.rpc('export_debts')
      if (error) return { message: toAppError(error, t('reports', 'failed')).message }
      const headers = [
        t('reports', 'colStudent'), t('reports', 'colStudentStatus'), t('reports', 'colPayer'), t('reports', 'colPhone'),
        t('reports', 'colLessonsDebtSom'), t('reports', 'colUnpaidSom'),
      ]
      const rows: CsvCell[][] = (data ?? []).map((r) => [
        r.student_name, r.student_status, r.payer_name, r.payer_phone,
        csvMoney(r.lessons_debt_tiyin), csvMoney(r.subscriptions_unpaid_tiyin),
      ])
      return { csv: toCsv(headers, rows), filename: `logocrm-debts-${stamp}.csv` }
    }
  }
}
