'use client'

import { useEffect } from 'react'
import Link from 'next/link'
import { Button, buttonVariants } from '@/components/ui/button'

/** Панель печатного вида речевой карты: сразу открывает печать, сама не печатается. */
export function PrintToolbar({ backHref }: { backHref: string }) {
  useEffect(() => {
    window.print()
  }, [])

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-md border border-border bg-muted/40 p-3 print:hidden">
      <p className="mr-auto text-sm text-muted-foreground">
        Речевая карта для школы и ПМПК. В окне печати выберите «Сохранить как PDF», чтобы получить файл.
      </p>
      <Button type="button" size="sm" onClick={() => window.print()}>
        Печать / PDF
      </Button>
      <Link href={backHref} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
        Вернуться к карточке
      </Link>
    </div>
  )
}
