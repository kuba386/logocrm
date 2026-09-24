/**
 * Подсказка заключения из пяти шкал diagnostics.speech_areas (0061) —
 * зеркало SQL-функции suggest_speech_conclusion, источник истины там.
 * «Нарушено» — значение ≤ 2 на шкале [1,5] (порог подтверждён владельцем
 * 24.09.2026); вне диапазона или нечисловое — «неизвестно», как и
 * отсутствующий ключ.
 *
 * ОНР — общий флаг onr_suspected, не конкретный уровень: у функции нет
 * возраста ребёнка на входе, а различие ОНР I / ЗРР и выбор уровня I–IV —
 * клиническое решение специалиста, не арифметика по трём шкалам (уровень
 * из среднего перепутал бы тяжесть местами и не отличил бы неговорящего
 * ребёнка с ОНР I от ребёнка с ЗРР). 'zrr' никогда не предлагается —
 * возрастная категория, не выводится из баллов по областям.
 *
 * norm тоже никогда не предлагается: функция не видит diagnostics.sounds
 * (карту звуков той же формы) — пять шкал в норме при искажённых звуках
 * дали бы кнопку «Применить: Речь в норме», хотя дислалия налицо.
 * «Норма» — решение, которое специалист принимает сам, глядя на всю
 * карту, не только на пять чисел; null у этой функции означает и
 * «недостаточно данных», и «нарушений по шкалам не найдено» — для
 * подсказки-намёка это не критично (в отличие от diagnostics.conclusion_code,
 * где два смысла null разбираются отдельно, Р11 0059).
 *
 * Подсказка никогда не проставляется в поле заключения сама — только
 * отдельная кнопка «Применить», которую нажимает специалист.
 */
export const SPEECH_AREA_KEYS = [
  'звукопроизношение',
  'фонематика',
  'лексика',
  'грамматика',
  'связная речь',
] as const

export type SpeechAreaKey = (typeof SPEECH_AREA_KEYS)[number]

export type SpeechConclusionSuggestion = 'fnr' | 'ffnr' | 'onr_suspected' | null

function validScore(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v) && v >= 1 && v <= 5
}

export function suggestSpeechConclusion(
  areas: Partial<Record<SpeechAreaKey, number>>,
): SpeechConclusionSuggestion {
  const scores = SPEECH_AREA_KEYS.map((key) => areas[key])
  if (!scores.every(validScore)) return null

  const [z, f, l, g, s] = scores as [number, number, number, number, number]
  const impaired = (v: number) => v <= 2

  if (impaired(l) || impaired(g) || impaired(s)) return 'onr_suspected'
  if (impaired(f)) return 'ffnr'
  if (impaired(z)) return 'fnr'
  return null
}
