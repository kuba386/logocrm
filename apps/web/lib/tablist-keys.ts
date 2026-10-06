import type { KeyboardEvent } from 'react'

/**
 * Стрелки по ряду вкладок (шаблон WAI-ARIA Tabs): ←/→ — соседняя вкладка,
 * Home/End — крайние. Вкладка выбирается сразу, фокус переходит на неё.
 * В Tab-порядке остаётся только выбранная вкладка (tabIndex 0 у неё, −1 у
 * остальных) — Tab из ряда ведёт сразу в содержимое, а не по всем вкладкам.
 */
export function onTablistKeyDown<K>(
  event: KeyboardEvent<HTMLElement>,
  keys: readonly K[],
  current: K,
  select: (key: K) => void,
) {
  const index = keys.indexOf(current)
  let next: number
  switch (event.key) {
    case 'ArrowRight':
      next = (index + 1) % keys.length
      break
    case 'ArrowLeft':
      next = (index - 1 + keys.length) % keys.length
      break
    case 'Home':
      next = 0
      break
    case 'End':
      next = keys.length - 1
      break
    default:
      return
  }
  const key = keys[next]
  if (key === undefined) return
  event.preventDefault()
  select(key)
  const tabs = event.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]')
  tabs[next]?.focus()
}
