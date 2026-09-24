import { ASSISTANT_TOOLS, assistantIntentSchema, type AssistantIntent, type AssistantIntentName } from './assistant'

/**
 * Ядро запроса к модели для ассистента (0064) — чистые функции без сети,
 * чтобы Vitest держал обещание ADR-009/В1: в теле запроса нет ничего, кроме
 * системной инструкции, сегодняшней даты и текста вопроса, а инструментов —
 * ровно столько, сколько разрешено роли (карта в SQL, assistant_intents_for).
 */

export const ASSISTANT_MODEL = 'gpt-4o-mini'

const WEEKDAYS = ['воскресенье', 'понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота']

export function assistantSystemPrompt(today: string): string {
  const weekday = WEEKDAYS[new Date(`${today}T12:00:00Z`).getUTCDay()]
  return [
    'Ты — маршрутизатор вопросов сотрудника логопедического центра.',
    `Сегодня ${today} (${weekday}). Даты считай от этого дня: «завтра» — следующий день, «на этой неделе» — с понедельника по воскресенье текущей недели, «за месяц» — с первого числа текущего месяца по сегодня.`,
    'Выбери ровно один инструмент и заполни его параметры. Если вопрос не про занятия, долги, абонементы, ребёнка или деньги центра — не вызывай ничего.',
    'Никогда не отвечай текстом и не проси уточнений: только вызов инструмента или его отсутствие.',
  ].join('\n')
}

export type ClassifyRequestBody = {
  model: string
  temperature: number
  max_tokens: number
  messages: { role: 'system' | 'user'; content: string }[]
  tools: { type: 'function'; function: { name: string; description: string; parameters: unknown; strict: boolean } }[]
  tool_choice: 'auto'
  parallel_tool_calls: boolean
}

/** Тело запроса — только из вопроса, даты и списка разрешённых намерений. */
export function buildClassifyRequest(question: string, today: string, allowedIntents: string[]): ClassifyRequestBody {
  const allowed = new Set(allowedIntents)
  return {
    model: ASSISTANT_MODEL,
    temperature: 0,
    max_tokens: 120,
    messages: [
      { role: 'system', content: assistantSystemPrompt(today) },
      { role: 'user', content: question },
    ],
    tools: ASSISTANT_TOOLS.filter((tool) => allowed.has(tool.name)).map((tool) => ({
      type: 'function' as const,
      function: { name: tool.name, description: tool.description, parameters: tool.parameters, strict: true },
    })),
    tool_choice: 'auto',
    parallel_tool_calls: false,
  }
}

export type ClassifyResponse = {
  model?: string
  usage?: { prompt_tokens?: number; completion_tokens?: number }
  choices?: { message?: { tool_calls?: { function?: { name?: string; arguments?: string } }[] } }[]
}

export type ClassifyParsed = {
  intent: AssistantIntent
  model: string
  tokensIn: number
  tokensOut: number
}

/**
 * Ответ модели — данные, не команды: проходит через zod, всё незнакомое или
 * не разрешённое роли превращается в «не понял».
 */
export function parseClassifyResponse(json: ClassifyResponse, allowedIntents: string[]): ClassifyParsed {
  const tokensIn = json.usage?.prompt_tokens ?? 0
  const tokensOut = json.usage?.completion_tokens ?? 0
  const model = json.model?.startsWith(ASSISTANT_MODEL) ? ASSISTANT_MODEL : (json.model ?? ASSISTANT_MODEL)

  const call = json.choices?.[0]?.message?.tool_calls?.[0]?.function
  let intent: AssistantIntent = { intent: 'unknown' }
  if (call?.name && allowedIntents.includes(call.name)) {
    let args: unknown = {}
    try {
      args = call.arguments ? JSON.parse(call.arguments) : {}
    } catch {
      args = {}
    }
    const parsed = assistantIntentSchema.safeParse({ ...(typeof args === 'object' && args ? args : {}), intent: call.name as AssistantIntentName })
    if (parsed.success) intent = parsed.data
  }
  return { intent, model, tokensIn, tokensOut }
}
