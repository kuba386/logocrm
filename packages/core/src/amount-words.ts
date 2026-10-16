/**
 * Сумма прописью для квитанции: 550000 тыйынов → «Пять тысяч пятьсот сом 00 тыйын».
 *
 * «Сом» и «тыйын» не склоняются — как в кассовых документах Кыргызстана и
 * как везде в интерфейсе («2 500 сом»). Склоняются разряды: «одна тысяча»,
 * «две тысячи», «пять тысяч» (тысяча — женского рода), «два миллиона».
 * Ошибка здесь молча печатает на квитанции не ту сумму — поэтому тесты.
 */

const UNITS_MASCULINE = ['', 'один', 'два', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять']
const UNITS_FEMININE = ['', 'одна', 'две', 'три', 'четыре', 'пять', 'шесть', 'семь', 'восемь', 'девять']
const TEENS = [
  'десять',
  'одиннадцать',
  'двенадцать',
  'тринадцать',
  'четырнадцать',
  'пятнадцать',
  'шестнадцать',
  'семнадцать',
  'восемнадцать',
  'девятнадцать',
]
const TENS = ['', '', 'двадцать', 'тридцать', 'сорок', 'пятьдесят', 'шестьдесят', 'семьдесят', 'восемьдесят', 'девяносто']
const HUNDREDS = ['', 'сто', 'двести', 'триста', 'четыреста', 'пятьсот', 'шестьсот', 'семьсот', 'восемьсот', 'девятьсот']

/** Разряды по три цифры, начиная с тысяч. */
const SCALES: { forms: [string, string, string]; feminine: boolean }[] = [
  { forms: ['тысяча', 'тысячи', 'тысяч'], feminine: true },
  { forms: ['миллион', 'миллиона', 'миллионов'], feminine: false },
  { forms: ['миллиард', 'миллиарда', 'миллиардов'], feminine: false },
]

/** 1 тысяча, 2–4 тысячи, 5–20 тысяч, 21 тысяча, 111 тысяч. */
function pluralForm(n: number, forms: [string, string, string]): string {
  const lastTwo = n % 100
  const last = n % 10
  if (lastTwo >= 11 && lastTwo <= 14) return forms[2]
  if (last === 1) return forms[0]
  if (last >= 2 && last <= 4) return forms[1]
  return forms[2]
}

/** 0..999 словами; пустой массив для нуля. */
function triadWords(n: number, feminine: boolean): string[] {
  const words: string[] = []
  const hundreds = Math.floor(n / 100)
  const rest = n % 100
  if (hundreds) words.push(HUNDREDS[hundreds]!)
  if (rest >= 10 && rest < 20) {
    words.push(TEENS[rest - 10]!)
  } else {
    const tens = Math.floor(rest / 10)
    const units = rest % 10
    if (tens) words.push(TENS[tens]!)
    if (units) words.push((feminine ? UNITS_FEMININE : UNITS_MASCULINE)[units]!)
  }
  return words
}

/** Целые сомы словами, с маленькой буквы: 21000 → «двадцать одна тысяча». */
export function somWords(som: number): string {
  if (!Number.isSafeInteger(som) || som < 0) {
    throw new TypeError(`som: ожидалось целое неотрицательное число, получено ${som}`)
  }
  if (som === 0) return 'ноль'
  if (som >= 1_000_000_000_000) throw new RangeError('Слишком большая сумма для квитанции')

  const words: string[] = []
  const units = som % 1000
  let rest = Math.floor(som / 1000)
  const scaled: string[][] = []
  for (const scale of SCALES) {
    const triad = rest % 1000
    rest = Math.floor(rest / 1000)
    scaled.push(triad ? [...triadWords(triad, scale.feminine), pluralForm(triad, scale.forms)] : [])
  }
  for (let i = scaled.length - 1; i >= 0; i -= 1) words.push(...scaled[i]!)
  words.push(...triadWords(units, false))
  return words.join(' ')
}

/**
 * Сумма в тыйынах прописью для квитанции: «Пять тысяч пятьсот сом 00 тыйын».
 * Отрицательная (возврат) — с «Минус»: на квитанции возврата пишут знак.
 */
export function amountInWords(tiyin: number): string {
  if (!Number.isSafeInteger(tiyin)) {
    throw new TypeError(`tiyin: ожидалось целое число, получено ${tiyin}`)
  }
  const abs = Math.abs(tiyin)
  const som = Math.floor(abs / 100)
  const kopecks = abs % 100
  const text = `${tiyin < 0 ? 'минус ' : ''}${somWords(som)} сом ${String(kopecks).padStart(2, '0')} тыйын`
  return text.charAt(0).toUpperCase() + text.slice(1)
}
