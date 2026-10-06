/**
 * Сохранённые фильтры (0094). Источник истины — SQL
 * `saved_filter_params_ok(page, params)`: он стоит в CHECK таблицы. Здесь —
 * зеркало: страница собирает params из адреса по allowlist и не предлагает
 * сохранить то, что база отвергнет. Меняешь одно — меняешь оба; общий набор
 * случаев — saved-filters.test.ts и tests/0094_saved_filters.test.sql.
 */

export type SavedFilterPage = 'schedule' | 'debts'

export type SavedFilterParams = Record<string, string>

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
/** Целые сомы 1…9 999 999 — в тыйынах укладывается в int4. */
const MIN_SOM = /^[1-9][0-9]{0,6}$/

const RULES: Record<SavedFilterPage, Record<string, (value: string) => boolean>> = {
  schedule: {
    teacher: (v) => UUID.test(v),
    room: (v) => v === 'none' || UUID.test(v),
  },
  debts: {
    filter: (v) => v === 'all' || v === 'debt' || v === 'zero',
    sort: (v) => v === 'amount' || v === 'name',
    min: (v) => MIN_SOM.test(v),
  },
}

/** Зеркало saved_filter_params_ok: только известные ключи страницы, только строки. */
export function savedFilterParamsOk(page: SavedFilterPage, params: unknown): boolean {
  if (params === null || typeof params !== 'object' || Array.isArray(params)) return false
  const rules = RULES[page]
  return Object.entries(params as Record<string, unknown>).every(
    ([key, value]) => typeof value === 'string' && Object.prototype.hasOwnProperty.call(rules, key) && rules[key]!(value),
  )
}

/**
 * Параметры для сохранения из текущего адреса: только ключи страницы и только
 * допустимые значения, пустые и значения по умолчанию отбрасываются — неделя
 * расписания не сохраняется никогда (набор открывается на текущей неделе).
 */
export function pickSavedFilterParams(
  page: SavedFilterPage,
  search: Record<string, string | string[] | undefined>,
): SavedFilterParams {
  const rules = RULES[page]
  const out: SavedFilterParams = {}
  for (const key of Object.keys(rules)) {
    const raw = search[key]
    const value = Array.isArray(raw) ? raw[0] : raw
    if (!value || !rules[key]!(value)) continue
    if (page === 'debts' && ((key === 'filter' && value === 'all') || (key === 'sort' && value === 'amount'))) continue
    out[key] = value
  }
  return out
}

/** Одинаковы ли два набора — для подсветки активного. */
export function sameSavedFilterParams(a: SavedFilterParams, b: SavedFilterParams): boolean {
  const ka = Object.keys(a)
  return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k])
}
