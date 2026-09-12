import ru from '@/messages/ru.json'

/**
 * Строки интерфейса — из apps/web/messages/ru.json (Definition of Done, этап
 * 5). Русский остаётся единственным языком: смысл в одном месте для строк, а
 * не в переключении языков. Ключ типизирован по JSON — опечатка в ключе не
 * компилируется, а не показывает пустоту.
 *
 * Плейсхолдеры вида {sum} подставляются через `vars`; лишние и отсутствующие
 * ключи не маскируются — строка остаётся с фигурными скобками, и это видно.
 */
type Messages = typeof ru

export function t<N extends keyof Messages, K extends keyof Messages[N] & string>(
  namespace: N,
  key: K,
  vars?: Record<string, string | number>,
): string {
  let text = String(ru[namespace][key])
  if (vars) {
    for (const [name, value] of Object.entries(vars)) {
      text = text.replaceAll(`{${name}}`, String(value))
    }
  }
  return text
}

/** Подпись для значения из lookup-словаря; неизвестный ключ — сам ключ, не пустота. */
export function label<N extends keyof Messages>(namespace: N, key: string): string {
  const dict = ru[namespace] as Record<string, string>
  return dict[key] ?? key
}
