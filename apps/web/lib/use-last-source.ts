'use client'

import { useEffect, useState } from 'react'

const KEY = 'logocrm:last-payment-source'

/**
 * Источник оплаты по умолчанию — последний выбранный на этом устройстве:
 * стойка обычно принимает одним способом (наличные или Mbank), и каждый раз
 * перещёлкивать с первого в списке — лишний шанс провести деньги не через ту
 * кассу. Чужой или архивный id из памяти не подставляется — только живой
 * источник этого центра. localStorage может быть недоступен (приватное окно)
 * — тогда просто первый в списке.
 *
 * preferred — источник, который знает сервер (например, которым по этому
 * абонементу платили в прошлый раз): он важнее памяти устройства.
 */
export function useLastSource(sources: { id: string }[], preferred?: string | null) {
  const known = (id: string | null | undefined): id is string => Boolean(id) && sources.some((s) => s.id === id)
  const [value, setValue] = useState(() => (known(preferred) ? preferred : (sources[0]?.id ?? '')))

  useEffect(() => {
    if (known(preferred)) return
    try {
      const saved = window.localStorage.getItem(KEY)
      if (known(saved)) setValue(saved)
    } catch {
      // Хранилище недоступно — остаётся первый источник.
    }
    // sources — новый массив на каждый рендер родителя; достаточно состава id.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preferred, sources.map((s) => s.id).join(',')])

  function remember(id: string) {
    setValue(id)
    try {
      window.localStorage.setItem(KEY, id)
    } catch {
      // Не запомнили — не страшно, в следующий раз будет первый в списке.
    }
  }

  return [value, remember] as const
}
