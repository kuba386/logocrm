'use client'

import Link from 'next/link'
import { Button, buttonVariants } from '@/components/ui/button'

/** Панель квитанции: печать или PDF, отправка в WhatsApp, назад. Сама не печатается. */
export function ReceiptToolbar({ backHref, whatsappHref }: { backHref: string; whatsappHref: string | null }) {
  return (
    <div className="flex flex-wrap items-center gap-2 rounded-md border border-border bg-muted/40 p-3 print:hidden">
      <p className="mr-auto text-sm text-muted-foreground">
        Квитанция для семьи. В окне печати можно выбрать «Сохранить как PDF».
      </p>
      <Button type="button" size="sm" onClick={() => window.print()}>
        Печать / PDF
      </Button>
      {whatsappHref ? (
        <a href={whatsappHref} target="_blank" rel="noreferrer" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
          Отправить в WhatsApp
        </a>
      ) : null}
      <Link href={backHref} className={buttonVariants({ variant: 'ghost', size: 'sm' })}>
        Назад
      </Link>
    </div>
  )
}
