'use client'

import Link from 'next/link'
import { createContext, useContext, useState, type ReactNode } from 'react'
import { X } from 'lucide-react'

/** Итог действия: текст и, если есть, ссылка — например «Квитанция» после оплаты. */
export type Notice = { text: string; href?: string; linkLabel?: string } | null

type Show = (notice: Notice) => void

const PageNoticeContext = createContext<Show | null>(null)

/** Строка итога с необязательной ссылкой; role=status — её ждут e2e (expectServerReply). */
export function NoticeLine({ notice, onClose }: { notice: Notice; onClose?: () => void }) {
  if (!notice) return null
  return (
    <p role="status" className="flex items-center gap-2 rounded-md bg-accent px-3 py-2 text-sm text-accent-foreground">
      <span className="min-w-0 flex-1">
        {notice.text}
        {notice.href ? (
          <>
            {' · '}
            <Link href={notice.href} className="font-medium underline underline-offset-4">
              {notice.linkLabel ?? 'Открыть'}
            </Link>
          </>
        ) : null}
      </span>
      {onClose ? (
        <button
          type="button"
          aria-label="Закрыть уведомление"
          onClick={onClose}
          className="-my-1 -mr-1 rounded p-1 text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
        >
          <X className="size-4" aria-hidden="true" />
        </button>
      ) : null}
    </p>
  )
}

/**
 * Итог действия, который переживает перерисовку того, кто его вызвал.
 * Пример — «Долги»: оплатили долг целиком, сервер перерисовал страницу, и
 * строки должника больше нет — уведомление внутри неё пропало бы вместе с
 * ней. Провайдер стоит выше, его состояние revalidatePath не сбрасывает, а
 * итог показывается внизу экрана — его видно, даже если действие было в
 * конце длинной карточки.
 */
export function PageNoticeProvider({ children }: { children: ReactNode }) {
  const [notice, setNotice] = useState<Notice>(null)
  return (
    <PageNoticeContext.Provider value={setNotice}>
      {children}
      {notice ? (
        <div className="pointer-events-none fixed inset-x-0 bottom-20 z-40 flex justify-center px-4 sm:bottom-6 print:hidden">
          <div className="pointer-events-auto w-full max-w-md shadow-lg">
            <NoticeLine notice={notice} onClose={() => setNotice(null)} />
          </div>
        </div>
      ) : null}
    </PageNoticeContext.Provider>
  )
}

/** null — провайдера выше нет: компонент показывает итог у себя. */
export function usePageNotice(): Show | null {
  return useContext(PageNoticeContext)
}
