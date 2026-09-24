'use server'

import { assistantQuestionSchema } from '@logocrm/contracts'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { t } from '@/lib/messages'
import { AssistantProviderError, classifyQuestion, isAssistantConfigured } from '@/lib/openai'
import { executeIntent, type AssistantAnswer } from './intents'

export type AssistantState = {
  question?: string
  answer?: AssistantAnswer
  notice?: string
  error?: string
  quota?: { used: number; limit: number }
}

type BeginPayload = { request_id: string; today: string; timezone: string; intents: string[] }

/**
 * Один вопрос — одна попытка — один вызов провайдера (0064, Р5):
 *   assistant_begin (гейт роли, PT402, квота, дата из базы, карта намерений)
 *   → OpenAI: только текст вопроса и дата (В1)
 *   → assistant_finish: расход в ai_usage по ставке из SQL, намерение под гейт (Р2/Р3)
 *   → исполнение намерения под сессией спросившего (RLS/RPC).
 * Закрытие попытки идёт ДО исполнения: вызов уже оплачен, даже если экран
 * потом не соберётся.
 */
export async function askAssistant(_prev: AssistantState, formData: FormData): Promise<AssistantState> {
  const parsedQuestion = assistantQuestionSchema.safeParse(String(formData.get('question') ?? ''))
  if (!parsedQuestion.success) {
    return { error: parsedQuestion.error.issues[0]?.message ?? 'Проверьте вопрос' }
  }
  const question = parsedQuestion.data

  if (!isAssistantConfigured()) {
    return { question, error: t('assistant', 'notConfigured') }
  }

  const supabase = await createClient()
  const { data: beginJson, error: beginError } = await supabase.rpc('assistant_begin')
  if (beginError) {
    return { question, error: toAppError(beginError, t('assistant', 'failed')).message }
  }
  const begin = beginJson as BeginPayload | null
  if (!begin?.request_id) {
    return { question, error: t('assistant', 'failed') }
  }

  let classified
  try {
    classified = await classifyQuestion(question, begin.today, begin.intents)
  } catch (error) {
    const reason = error instanceof AssistantProviderError ? error.message : 'Провайдер недоступен'
    await supabase.rpc('assistant_finish', { p_request_id: begin.request_id, p_status: 'failed', p_error: reason })
    return { question, error: t('assistant', 'providerFailed') }
  }

  const intentName = classified.intent.intent === 'unknown' ? undefined : classified.intent.intent
  const { error: finishError } = await supabase.rpc('assistant_finish', {
    p_request_id: begin.request_id,
    p_status: 'done',
    p_intent: intentName,
    p_model: classified.model,
    p_tokens_in: classified.tokensIn,
    p_tokens_out: classified.tokensOut,
  })
  if (finishError) {
    // 42501 «этот вопрос вашей роли недоступен» и прочее — общим разбором.
    return { question, error: toAppError(finishError, t('assistant', 'failed')).message }
  }

  const quota = await readQuota(supabase)

  if (classified.intent.intent === 'unknown') {
    return { question, notice: t('assistant', 'unknown'), quota }
  }

  try {
    const answer = await executeIntent(supabase, classified.intent, begin.timezone, begin.today)
    return answer ? { question, answer, quota } : { question, notice: t('assistant', 'unknown'), quota }
  } catch (error) {
    return { question, error: toAppError(error as { code?: string; message?: string }, t('assistant', 'failed')).message, quota }
  }
}

async function readQuota(supabase: Awaited<ReturnType<typeof createClient>>): Promise<{ used: number; limit: number } | undefined> {
  const { data } = await supabase.rpc('assistant_quota')
  const q = data as { used?: number; limit?: number } | null
  if (!q || typeof q.used !== 'number' || typeof q.limit !== 'number') return undefined
  return { used: q.used, limit: q.limit }
}
