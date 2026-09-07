'use server'

import { revalidatePath } from 'next/cache'
import { createStudentSchema, findPayerByPhoneSchema, updateStudentSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'

export type StudentState = { error?: string; notice?: string; studentId?: string }

export type PayerMatch = {
  id: string
  fullName: string
  phone: string
  relation: string | null
  childrenCount: number
}

function optional(formData: FormData, key: string): string | undefined {
  const value = String(formData.get(key) ?? '').trim()
  return value === '' ? undefined : value
}

/**
 * Подсказка на форме «добавить ученика»: администратор вводит номер, система
 * отвечает «эта мама уже есть». Так дубли не появляются в принципе.
 */
export async function findPayerByPhone(phone: string): Promise<PayerMatch | null> {
  const parsed = findPayerByPhoneSchema.safeParse({ phone })
  if (!parsed.success) return null

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('find_payer_by_phone', { p_phone: parsed.data.phone })

  if (error || !data?.[0]) return null

  const match = data[0]
  return {
    id: match.id,
    fullName: match.full_name,
    phone: match.phone,
    relation: match.relation,
    childrenCount: match.children_count,
  }
}

export async function createStudent(_prev: StudentState, formData: FormData): Promise<StudentState> {
  const existingPayerId = optional(formData, 'payerId')

  const parsed = createStudentSchema.safeParse({
    fullName: String(formData.get('fullName') ?? ''),
    birthDate: optional(formData, 'birthDate'),
    gender: optional(formData, 'gender'),
    payer: existingPayerId
      ? { existingId: existingPayerId }
      : {
          fullName: String(formData.get('payerFullName') ?? ''),
          phone: String(formData.get('payerPhone') ?? ''),
          relation: optional(formData, 'payerRelation'),
        },
    primaryTeacherId: optional(formData, 'primaryTeacherId'),
    source: optional(formData, 'source'),
    notes: optional(formData, 'notes'),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const { payer } = parsed.data
  const supabase = await createClient()

  const { data, error } = await supabase.rpc('create_student_with_payer', {
    p_full_name: parsed.data.fullName,
    p_payer_id: 'existingId' in payer ? payer.existingId : undefined,
    p_payer_full_name: 'existingId' in payer ? undefined : payer.fullName,
    p_payer_phone: 'existingId' in payer ? undefined : payer.phone,
    p_payer_relation: 'existingId' in payer ? undefined : payer.relation,
    p_birth_date: parsed.data.birthDate || undefined,
    p_gender: parsed.data.gender,
    p_primary_teacher_id: parsed.data.primaryTeacherId,
    p_source: parsed.data.source || undefined,
    p_notes: parsed.data.notes || undefined,
  })

  if (error) {
    return { error: error.message || 'Не удалось добавить ученика' }
  }

  revalidatePath('/app/students')
  revalidatePath('/app/payers')
  return { notice: 'Ученик добавлен', studentId: data?.[0]?.student_id }
}

export async function updateStudent(_prev: StudentState, formData: FormData): Promise<StudentState> {
  const parsed = updateStudentSchema.safeParse({
    id: String(formData.get('id') ?? ''),
    fullName: optional(formData, 'fullName'),
    birthDate: optional(formData, 'birthDate'),
    gender: optional(formData, 'gender'),
    primaryTeacherId: optional(formData, 'primaryTeacherId'),
    status: optional(formData, 'status'),
    source: optional(formData, 'source'),
    notes: optional(formData, 'notes'),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Проверьте введённые данные' }
  }

  const supabase = await createClient()

  const { error } = await supabase
    .from('students')
    .update({
      full_name: parsed.data.fullName,
      birth_date: parsed.data.birthDate || null,
      gender: parsed.data.gender ?? null,
      primary_teacher_id: parsed.data.primaryTeacherId || null,
      status: parsed.data.status,
      source: parsed.data.source || null,
      notes: parsed.data.notes || null,
    })
    .eq('id', parsed.data.id)

  if (error) {
    return { error: error.message || 'Не удалось сохранить изменения' }
  }

  revalidatePath('/app/students')
  revalidatePath(`/app/students/${parsed.data.id}`)
  return { notice: 'Сохранено' }
}

export async function archiveStudent(_prev: StudentState, formData: FormData): Promise<StudentState> {
  const id = String(formData.get('id') ?? '')
  if (!id) return { error: 'Ученик не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('archive_student', { p_id: id })

  if (error) return { error: error.message || 'Не удалось отправить в архив' }

  revalidatePath('/app/students')
  revalidatePath(`/app/students/${id}`)
  return { notice: 'Ученик в архиве' }
}

export async function restoreStudent(_prev: StudentState, formData: FormData): Promise<StudentState> {
  const id = String(formData.get('id') ?? '')
  if (!id) return { error: 'Ученик не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('restore_student', { p_id: id })

  if (error) return { error: error.message || 'Не удалось восстановить' }

  revalidatePath('/app/students')
  revalidatePath(`/app/students/${id}`)
  return { notice: 'Ученик восстановлен' }
}
