/**
 * Адрес возврата после входа (`next`): только путь внутри приложения.
 *
 * `next` приходит из адреса страницы входа — его может подставить кто угодно.
 * Без проверки `/login?next=https://чужой-сайт` после ввода пароля уводил бы
 * человека наружу (открытый редирект), а `//чужой-сайт` браузер тоже читает
 * как другой хост. Разрешён только путь от корня, с параметрами.
 */
export function safeNextPath(value: unknown, fallback = '/app'): string {
  if (typeof value !== 'string' || value === '') return fallback
  if (!value.startsWith('/')) return fallback
  // «//host» и «/\host» — другой хост для браузера; управляющие символы — мусор.
  if (value.startsWith('//') || value.startsWith('/\\')) return fallback
  if (/[\u0000-\u001f\u007f]/.test(value)) return fallback
  return value
}
