'use client'

import { useState, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'

/** «Изменить» / «Свернуть» над формой, которая нужна изредка. */
export function Disclosure({ label, children }: { label: string; children: ReactNode }) {
  const [open, setOpen] = useState(false)

  return (
    <div className="space-y-3">
      <Button type="button" variant="ghost" size="sm" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        {open ? 'Свернуть' : label}
      </Button>
      {open ? <div className="rounded-md border border-border bg-muted/40 p-3">{children}</div> : null}
    </div>
  )
}
