/**
 * Тег, который закрывает упражнение для домашнего задания (0081). Зеркало SQL
 * public.exercise_is_specialist_only — источник истины там, триггер на
 * homework_exercises отказывает сам; здесь только чтобы форма ДЗ не
 * предлагала такие упражнения. Меняешь одно — меняешь оба; случаи общие с
 * tests/0081.
 */
export const SPECIALIST_ONLY_TAG = 'только специалист'

// Тот же набор, что btrim(t, E' \t\r\n') в SQL: String.trim снимает больше (NBSP и др.).
const EDGE_SPACE = /^[ \t\r\n]+|[ \t\r\n]+$/g

export function isSpecialistOnly(tags: readonly string[] | null | undefined): boolean {
  return (tags ?? []).some((tag) => tag.replace(EDGE_SPACE, '').toLowerCase() === SPECIALIST_ONLY_TAG)
}
