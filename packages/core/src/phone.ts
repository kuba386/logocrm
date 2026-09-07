/**
 * Телефоны Кыргызстана: код +996 и девять цифр.
 *
 * Та же логика продублирована в SQL (normalize_kg_phone) — она нужна там для
 * уникального индекса по нормализованному номеру. Расхождение между реализациями
 * приведёт к дублям плательщиков, поэтому наборы примеров в тестах совпадают.
 */

const KG_CODE = '996'
const LOCAL_LENGTH = 9

/** Приводит номер к виду +996XXXXXXXXX. Возвращает null, если это не номер. */
export function normalizeKgPhone(input: string | null | undefined): string | null {
  if (!input) return null

  const digits = input.replace(/\D/g, '')

  // 996XXXXXXXXX
  if (digits.length === KG_CODE.length + LOCAL_LENGTH && digits.startsWith(KG_CODE)) {
    return `+${digits}`
  }

  // 0XXXXXXXXX — местная запись с ведущим нулём
  if (digits.length === LOCAL_LENGTH + 1 && digits.startsWith('0')) {
    return `+${KG_CODE}${digits.slice(1)}`
  }

  // XXXXXXXXX — девять цифр без кода
  if (digits.length === LOCAL_LENGTH) {
    return `+${KG_CODE}${digits}`
  }

  return null
}

export function isValidKgPhone(input: string | null | undefined): boolean {
  return normalizeKgPhone(input) !== null
}

/** Для интерфейса: +996700123456 → «+996 700 123 456». */
export function formatKgPhone(input: string | null | undefined): string {
  const normalized = normalizeKgPhone(input)
  if (!normalized) return input ?? ''

  const local = normalized.slice(4)
  return `+${KG_CODE} ${local.slice(0, 3)} ${local.slice(3, 6)} ${local.slice(6)}`
}

/** Для ссылок wa.me — там нужны только цифры. */
export function whatsappNumber(input: string | null | undefined): string | null {
  const normalized = normalizeKgPhone(input)
  return normalized ? normalized.slice(1) : null
}
