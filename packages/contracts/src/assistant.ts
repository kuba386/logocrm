import { z } from 'zod'

/**
 * AI-ассистент администратора (0064). Модель разбирает вопрос обычным языком
 * в ОДНО намерение с параметрами — и только. Наружу уходит текст вопроса и
 * сегодняшняя дата; ответ собирает база под правами спросившего, рисует
 * интерфейс (решение владельца 24.09.2026, ADR-009).
 *
 * Схемы здесь — источник истины для валидации ответа модели: то, что она
 * вернула, проходит через zod, а не исполняется как есть.
 */

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Дата в формате ГГГГ-ММ-ДД')

export const lessonsOnSchema = z.object({
  intent: z.literal('lessons_on'),
  date: isoDate,
})

export const debtorsSchema = z.object({
  intent: z.literal('debtors'),
  /** Порог в сомах; 0 — все должники. */
  min_som: z.number().int().min(0).max(1_000_000).default(0),
})

export const expiringSubscriptionsSchema = z.object({
  intent: z.literal('expiring_subscriptions'),
  /** Срок абонемента истекает в ближайшие N дней. */
  days: z.number().int().min(0).max(60).default(7),
  /** Или осталось не больше N занятий. */
  lessons_left: z.number().int().min(0).max(10).default(2),
})

export const studentInfoSchema = z.object({
  intent: z.literal('student_info'),
  /** Имя ребёнка или родителя как в вопросе — ищется global_search под RLS. */
  name: z.string().trim().min(2).max(80),
})

export const paymentsSummarySchema = z.object({
  intent: z.literal('payments_summary'),
  from: isoDate,
  to: isoDate,
})

export const unknownIntentSchema = z.object({
  intent: z.literal('unknown'),
})

// Межполевые проверки — поверх union: discriminatedUnion не принимает
// схемы с refine в качестве членов.
export const assistantIntentSchema = z
  .discriminatedUnion('intent', [
    lessonsOnSchema,
    debtorsSchema,
    expiringSubscriptionsSchema,
    studentInfoSchema,
    paymentsSummarySchema,
    unknownIntentSchema,
  ])
  .superRefine((v, ctx) => {
    if (v.intent !== 'payments_summary') return
    if (v.from > v.to) ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Начало периода позже его конца', path: ['from'] })
    if (daysBetween(v.from, v.to) > 366) ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Период — не больше года', path: ['to'] })
  })
export type AssistantIntent = z.infer<typeof assistantIntentSchema>
export type AssistantIntentName = AssistantIntent['intent']

export const assistantQuestionSchema = z
  .string()
  .trim()
  .min(2, 'Слишком короткий вопрос')
  .max(300, 'Слишком длинный вопрос — до 300 символов')

/**
 * Описание инструментов для function calling — зеркало zod-схем выше.
 * Вручную, без генератора: набор маленький, а лишняя зависимость ради
 * пяти объектов не окупается. Vitest держит их в согласии.
 */
export type AssistantTool = {
  name: Exclude<AssistantIntentName, 'unknown'>
  description: string
  parameters: {
    type: 'object'
    properties: Record<string, { type: string; description: string }>
    required: string[]
    additionalProperties: false
  }
}

export const ASSISTANT_TOOLS: AssistantTool[] = [
  {
    name: 'lessons_on',
    description: 'Занятия центра на конкретную дату («какие занятия завтра», «расписание на пятницу», «что сегодня»).',
    parameters: {
      type: 'object',
      properties: { date: { type: 'string', description: 'Дата ГГГГ-ММ-ДД, вычисленная от сегодняшнего дня' } },
      required: ['date'],
      additionalProperties: false,
    },
  },
  {
    name: 'debtors',
    description: 'Кто должен денег за занятия («кто должен», «должники больше 5000»).',
    parameters: {
      type: 'object',
      properties: { min_som: { type: 'integer', description: 'Порог долга в сомах, 0 — все должники' } },
      required: ['min_som'],
      additionalProperties: false,
    },
  },
  {
    name: 'expiring_subscriptions',
    description: 'У кого заканчивается абонемент: по сроку в ближайшие N дней или по остатку занятий.',
    parameters: {
      type: 'object',
      properties: {
        days: { type: 'integer', description: 'Срок истекает в ближайшие N дней (по умолчанию 7)' },
        lessons_left: { type: 'integer', description: 'Или осталось не больше N занятий (по умолчанию 2)' },
      },
      required: ['days', 'lessons_left'],
      additionalProperties: false,
    },
  },
  {
    name: 'student_info',
    description: 'Сведения о ребёнке или семье по имени: абонемент, остаток, долг, ближайшее занятие.',
    parameters: {
      type: 'object',
      properties: { name: { type: 'string', description: 'Имя ребёнка или родителя так, как оно написано в вопросе' } },
      required: ['name'],
      additionalProperties: false,
    },
  },
  {
    name: 'payments_summary',
    description: 'Сколько денег пришло за период («касса за сегодня», «выручка за сентябрь»).',
    parameters: {
      type: 'object',
      properties: {
        from: { type: 'string', description: 'Начало периода ГГГГ-ММ-ДД' },
        to: { type: 'string', description: 'Конец периода ГГГГ-ММ-ДД (включительно)' },
      },
      required: ['from', 'to'],
      additionalProperties: false,
    },
  },
]

/** Примеры для экрана — те же формулировки, что в Backlog владельца. */
export const ASSISTANT_EXAMPLES = [
  'Какие занятия завтра?',
  'Кто должен денег?',
  'У кого заканчивается абонемент?',
  'Сколько пришло денег за эту неделю?',
]

function daysBetween(from: string, to: string): number {
  const a = Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)) - 1, Number(from.slice(8, 10)))
  const b = Date.UTC(Number(to.slice(0, 4)), Number(to.slice(5, 7)) - 1, Number(to.slice(8, 10)))
  return Math.round((b - a) / 86_400_000)
}
