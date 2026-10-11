'use client'

import { useState, type ReactNode } from 'react'
import { Button, type ButtonProps } from '@/components/ui/button'
import { Dialog } from '@/components/ui/dialog'

/** Кнопка, открывающая форму в диалоге: в шапке страницы или в строке таблицы (variant/size). */
export function DialogButton({
  label,
  title,
  description,
  children,
  variant,
  size,
}: {
  label: string
  title: string
  description?: string
  children: ReactNode
  variant?: ButtonProps['variant']
  size?: ButtonProps['size']
}) {
  const [open, setOpen] = useState(false)

  return (
    <>
      <Button type="button" variant={variant} size={size} onClick={() => setOpen(true)}>
        {label}
      </Button>
      <Dialog open={open} onClose={() => setOpen(false)} title={title} description={description}>
        {children}
      </Dialog>
    </>
  )
}
