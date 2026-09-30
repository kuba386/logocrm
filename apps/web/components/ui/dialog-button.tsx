'use client'

import { useState, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'

/** Кнопка в шапке страницы, открывающая форму в диалоге. */
export function DialogButton({
  label,
  title,
  description,
  children,
}: {
  label: string
  title: string
  description?: string
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)

  return (
    <>
      <Button type="button" onClick={() => setOpen(true)}>
        {label}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={title} description={description}>
        {children}
      </Dialog>
    </>
  )
}
