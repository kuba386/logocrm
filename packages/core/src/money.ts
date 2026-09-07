/**
 * Деньги в системе — целые тыйыны (1 сом = 100 тыйынов).
 * Никаких float в БД и в бизнес-логике: см. docs/Database.md.
 */

export const TIYIN_IN_SOM = 100

/** Сомы → тыйыны. Округление до ближайшего тыйына. */
export function toTiyin(som: number): number {
  assertFinite(som, 'som')
  return Math.round(som * TIYIN_IN_SOM)
}

/** Тыйыны → сомы. Результат может быть дробным — только для отображения. */
export function toSom(tiyin: number): number {
  assertInteger(tiyin, 'tiyin')
  return tiyin / TIYIN_IN_SOM
}

/**
 * Цена одного занятия внутри абонемента.
 * Округление вниз: центр не может получить больше, чем заплатил родитель,
 * остаток от деления остаётся в пользу родителя.
 */
export function lessonPrice(subscriptionPriceTiyin: number, lessonsCount: number): number {
  assertInteger(subscriptionPriceTiyin, 'subscriptionPriceTiyin')
  assertInteger(lessonsCount, 'lessonsCount')

  if (subscriptionPriceTiyin < 0) {
    throw new RangeError('Цена абонемента не может быть отрицательной')
  }
  if (lessonsCount <= 0) {
    throw new RangeError('Количество занятий должно быть больше нуля')
  }

  return Math.floor(subscriptionPriceTiyin / lessonsCount)
}

/** Форматирование для интерфейса: 250000 → «2 500 сом». */
export function formatSom(tiyin: number): string {
  const som = toSom(tiyin)
  const formatted = new Intl.NumberFormat('ru-RU', {
    minimumFractionDigits: Number.isInteger(som) ? 0 : 2,
    maximumFractionDigits: 2,
  }).format(som)
  return `${formatted} сом`
}

function assertFinite(value: number, name: string): void {
  if (!Number.isFinite(value)) {
    throw new TypeError(`${name}: ожидалось конечное число, получено ${value}`)
  }
}

function assertInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value)) {
    throw new TypeError(`${name}: ожидалось целое число, получено ${value}`)
  }
}
