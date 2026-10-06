/** «2026-09» → первое число и первое число следующего месяца. */
export function monthBounds(month: string): { first: string; next: string } {
  const [y, m] = month.split('-').map(Number)
  const nextY = m === 12 ? y! + 1 : y!
  const nextM = m === 12 ? 1 : m! + 1
  return { first: `${month}-01`, next: `${nextY}-${String(nextM).padStart(2, '0')}-01` }
}

/** «2026-09» + 1 → «2026-10». */
export function shiftMonth(month: string, delta: number): string {
  const [y, m] = month.split('-').map(Number)
  const total = y! * 12 + (m! - 1) + delta
  return `${Math.floor(total / 12)}-${String((total % 12) + 1).padStart(2, '0')}`
}
