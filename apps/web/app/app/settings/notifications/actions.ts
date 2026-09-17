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
 */
export async function saveTemplate(_prev: TemplateState, formData: FormData): Promise<TemplateState> {
  const eventType = text(formData, 'eventType')
  const channel = text(formData, 'channel')
  const body = String(formData.get('text') ?? '').trim()
  const isActive = formData.get('isActive') === 'on'

  if (!eventType || !channel || !body) return { message: t('notifications', 'saveFailed') }

  const supabase = await createClient()

  const { data: existing, error: readError } = await supabase
    .from('message_templates')
    .select('id')
    .eq('event_type', eventType)
    .eq('channel', channel)
    .not('center_id', 'is', null)
    .is('deleted_at', null)
    .maybeSingle()
  if (readError) return toAppError(readError, t('notifications', 'saveFailed'))

  const { error } = existing
    ? await supabase
        .from('message_templates')
        .update({ text: body, is_active: isActive })
        .eq('id', existing.id)
    : await supabase
        .from('message_templates')
        .insert({ event_type: eventType, channel, text: body, is_active: isActive })
  if (error) return toAppError(error, t('notifications', 'saveFailed'))

  revalidatePath('/app/settings/notifications')
  return { notice: t('notifications', 'saved') }
}

/** Убрать текст центра — дальше действует текст платформы. */
export async function resetTemplate(_prev: TemplateState, formData: FormData): Promise<TemplateState> {
  const eventType = text(formData, 'eventType')
  const channel = text(formData, 'channel')

  const supabase = await createClient()
  const { error } = await supabase
    .from('message_templates')
    .update({ deleted_at: new Date().toISOString() })
    .eq('event_type', eventType)
    .eq('channel', channel)
    .not('center_id', 'is', null)
    .is('deleted_at', null)
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
