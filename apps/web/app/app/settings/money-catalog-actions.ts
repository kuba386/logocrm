'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import type { CatalogState } from './services/actions'

/**
 * Способы оплаты, статьи расходов и причины скидок (0101) — справочники денег (0013, 0016): пишут
 * owner/admin и бухгалтер (RLS tenant_admin + apply_role_rls finance write,
 * 0028), архив и восстановление — RPC под can_finance (0027). Прямой update
 * — только справочные поля (grant update (code, name, is_active, sort)).
 */

type Catalog = 'payment_sources' | 'expense_categories' | 'discount_reasons'

const PATHS: Record<Catalog, string> = {
  payment_sources: '/app/settings/payment-sources',
  expense_categories: '/app/settings/expense-categories',
  discount_reasons: '/app/settings/discount-reasons',
}

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

/**
 * Код нужен базе для группировки в отчётах (переименование «Mbank» → «MBank»
 * не должно её ломать, 0013) и уникален среди живых строк центра. Человеку он
 * не показывается — новой строке достаточно случайного.
 */
function newCode(): string {
  return `c${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`
}

function revalidateMoney(catalog: Catalog) {
  revalidatePath(PATHS[catalog])
  // Списки выбора живут в формах оплаты и расхода.
  revalidatePath('/app/finance')
  revalidatePath('/app/debts')
  revalidatePath('/app/students/[id]', 'page')
}

async function save(catalog: Catalog, formData: FormData, what: string): Promise<CatalogState> {
  const id = text(formData, 'id')
  const name = text(formData, 'name')
  const sortRaw = text(formData, 'sort')
  const sort = sortRaw === '' ? null : Number(sortRaw)

  if (name.length < 2) return { message: `Укажите название — от двух букв` }
  if (name.length > 60) return { message: 'Название — не длиннее 60 символов' }
  if (sort !== null && (!Number.isInteger(sort) || sort < 0 || sort > 10_000)) {
    return { message: 'Порядок — целое число от 0 до 10 000' }
  }

  const supabase = await createClient()
  const payload = {
    name,
    is_active: formData.get('isActive') === 'on',
    ...(sort === null ? {} : { sort }),
  }

  const { error } = id
    ? await supabase.from(catalog).update(payload).eq('id', id)
    : await supabase.from(catalog).insert({ ...payload, code: newCode() })

  if (error) return toAppError(error, `Не удалось сохранить ${what}`)

  revalidateMoney(catalog)
  return { message: '', notice: 'Сохранено' }
}

export async function savePaymentSource(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  return save('payment_sources', formData, 'способ оплаты')
}

export async function saveExpenseCategory(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  return save('expense_categories', formData, 'статью расхода')
}

export async function saveDiscountReason(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  return save('discount_reasons', formData, 'причину скидки')
}

export async function archivePaymentSource(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Способ оплаты не найден' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_payment_source', { p_id: id })
  if (error) return toAppError(error, 'Не удалось отправить способ оплаты в архив')
  revalidateMoney('payment_sources')
  return { message: '', notice: 'В архиве' }
}

export async function restorePaymentSource(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Способ оплаты не найден' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_payment_source', { p_id: id })
  if (error) return toAppError(error, 'Не удалось восстановить способ оплаты')
  revalidateMoney('payment_sources')
  return { message: '', notice: 'Восстановлен' }
}

export async function archiveExpenseCategory(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Статья расхода не найдена' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_expense_category', { p_id: id })
  if (error) return toAppError(error, 'Не удалось отправить статью в архив')
  revalidateMoney('expense_categories')
  return { message: '', notice: 'В архиве' }
}

export async function restoreExpenseCategory(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Статья расхода не найдена' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_expense_category', { p_id: id })
  if (error) return toAppError(error, 'Не удалось восстановить статью')
  revalidateMoney('expense_categories')
  return { message: '', notice: 'Восстановлена' }
}

export async function archiveDiscountReason(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Причина скидки не найдена' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_discount_reason', { p_id: id })
  if (error) return toAppError(error, 'Не удалось отправить причину в архив')
  revalidateMoney('discount_reasons')
  return { message: '', notice: 'В архиве' }
}

export async function restoreDiscountReason(_prev: CatalogState, formData: FormData): Promise<CatalogState> {
  const id = text(formData, 'id')
  if (!id) return { message: 'Причина скидки не найдена' }
  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_discount_reason', { p_id: id })
  if (error) return toAppError(error, 'Не удалось восстановить причину')
  revalidateMoney('discount_reasons')
  return { message: '', notice: 'Восстановлена' }
}
