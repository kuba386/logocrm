import 'server-only'
import { buildClassifyRequest, parseClassifyResponse, type ClassifyParsed, type ClassifyResponse } from '@logocrm/contracts'

/**
 * Единственное место, где веб зовёт OpenAI (0064). Провайдер один — OpenAI
 * (ADR-009, решение 20.09.2026); ключ живёт только на сервере, 'server-only'
 * ломает сборку при импорте из клиентского компонента.
 *
 * Тело запроса собирает buildClassifyRequest из @logocrm/contracts — там
 * Vitest держит обещание В1: наружу уходят только инструкция, дата и текст
 * вопроса, инструментов ровно столько, сколько разрешено роли. Один вопрос —
 * ровно один вызов (Р5).
 */

export function isAssistantConfigured(): boolean {
  return Boolean(process.env.OPENAI_API_KEY)
}

export class AssistantProviderError extends Error {}

export async function classifyQuestion(question: string, today: string, allowedIntents: string[]): Promise<ClassifyParsed> {
  const key = process.env.OPENAI_API_KEY
  if (!key) throw new AssistantProviderError('OPENAI_API_KEY не задан')

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15_000)
  let response: Response
  try {
    response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      signal: controller.signal,
      body: JSON.stringify(buildClassifyRequest(question, today, allowedIntents)),
    })
  } catch (error) {
    throw new AssistantProviderError(
      error instanceof Error && error.name === 'AbortError' ? 'Провайдер не ответил за 15 секунд' : 'Провайдер недоступен',
    )
  } finally {
    clearTimeout(timer)
  }

  if (!response.ok) {
    throw new AssistantProviderError(`Провайдер ответил ${response.status}`)
  }

  return parseClassifyResponse((await response.json()) as ClassifyResponse, allowedIntents)
}
