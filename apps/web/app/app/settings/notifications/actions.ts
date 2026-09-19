'use server'

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'

export type TemplateState = { message?: string; notice?: string; preview?: string }

function text(formData: FormData, key: string): string {
  return String(formData.get(key) ?? '').trim()
}

/**
 * Строка центра перекрывает текст платформы (0034 Р1). Пустой текст — не
 * «молчать»: для тишины есть флаг «Отправлять», а вернуться к тексту
 * платформы — отдельная кнопка.
 *
 * Запись — через RPC upsert_message_template (0037), не insert/update
 * таблицы напрямую: center_id и права проверяются внутри функции. Прямой
 * insert без center_id падал RLS (таблица не проходит целиком под
 * apply_tenant_rls — center_id nullable ради строк-дефолтов платформы), а
 * insert-then-select здесь был бы гонкой на двух кликах «Сохранить» подряд.
 */
export async function saveTemplate(_prev: TemplateState, formData: FormData): Promise<TemplateState> {
  const eventType = text(formData, 'eventType')
  const channel = text(formData, 'channel')
  const body = String(formData.get('text') ?? '').trim()
  const isActive = formData.get('isActive') === 'on'

  if (!eventType || !channel || !body) return { message: t('notifications', 'saveFailed') }

  const supabase = await createClient()
  const { error } = await supabase.rpc('upsert_message_template', {
    p_event_type: eventType,
    p_channel: channel,
    p_text: body,
    p_is_active: isActive,
  })
  if (error) return toAppError(error, t('notifications', 'saveFailed'))

  revalidatePath('/app/settings/notifications')
  return { notice: t('notifications', 'saved') }
}

/** Убрать текст центра — дальше действует текст платформы. RPC reset_message_template (0037): прямой update({deleted_at}) не проходил RLS на returning * обновлённой строки. */
export async function resetTemplate(_prev: TemplateState, formData: FormData): Promise<TemplateState> {
  const eventType = text(formData, 'eventType')
  const channel = text(formData, 'channel')

  const supabase = await createClient()
  const { error } = await supabase.rpc('reset_message_template', {
    p_event_type: eventType,
    p_channel: channel,
  })
  if (error) return toAppError(error, t('notifications', 'saveFailed'))

  revalidatePath('/app/settings/notifications')
  return { notice: t('notifications', 'resetDone') }
}

/** Тот же рендер, что уходит в сообщении — иначе предпросмотр обманывает. */
export async function previewTemplate(_prev: TemplateState, formData: FormData): Promise<TemplateState> {
  const body = String(formData.get('text') ?? '')
  const supabase = await createClient()
  const { data, error } = await supabase.rpc('preview_message', { p_text: body })
  if (error) return toAppError(error, t('notifications', 'previewFailed'))
  return { preview: data ?? '' }
}
