'use client'

import { useCallback, useEffect, useRef, type FormEvent } from 'react'

/**
 * React 19 после действия <form action> сбрасывает форму к defaultValue —
 * и при успехе, и когда действие вернуло ошибку. Логопед заполнил карту из
 * 24 звуков, сервер отказал — всё пропало; в онлайн-записи список услуг
 * молча возвращался к первой, и повторная отправка уходила с чужой услугой.
 *
 * Хук запоминает значения формы в момент отправки и, если ответ — ошибка,
 * возвращает их после сброса. Успех по-прежнему очищает форму (так и
 * задумано у форм «Добавить»). <form action> остаётся — значит,
 * useFormStatus (блокировка кнопки, ConfirmSubmit) работает как раньше;
 * переход на onSubmit + startTransition (#198) это бы сломал.
 *
 * Пароли не восстанавливаются — их после ошибки вводят заново.
 *
 *   const keep = useKeepValuesOnError(state, Boolean(state.error))
 *   <form action={formAction} {...keep}>
 *
 * Аудит UX 6.10.2026 (правила UX55, UX106).
 */
export function useKeepValuesOnError(state: unknown, failed: boolean, onSubmitExtra?: (event: FormEvent<HTMLFormElement>) => void) {
  const ref = useRef<HTMLFormElement>(null)
  const snapshot = useRef<FormData | null>(null)

  const onSubmit = useCallback(
    (event: FormEvent<HTMLFormElement>) => {
      onSubmitExtra?.(event)
      if (event.defaultPrevented) return
      snapshot.current = new FormData(event.currentTarget)
    },
    [onSubmitExtra],
  )

  // Эффект идёт после коммита, в котором React уже сбросил форму.
  useEffect(() => {
    const form = ref.current
    const data = snapshot.current
    snapshot.current = null
    if (!form || !data || !failed) return
    restoreFormValues(form, data)
  }, [state, failed])

  return { ref, onSubmit }
}

/** Значения из FormData обратно в поля формы; одноимённые поля — по порядку. */
export function restoreFormValues(form: HTMLFormElement, data: FormData) {
  const seen = new Map<string, number>()
  const nth = (name: string) => {
    const i = seen.get(name) ?? 0
    seen.set(name, i + 1)
    return i
  }

  for (const element of Array.from(form.elements)) {
    if (element instanceof HTMLInputElement) {
      if (!element.name || element.disabled) continue
      if (['file', 'hidden', 'password', 'submit', 'button', 'reset'].includes(element.type)) continue
      if (element.type === 'checkbox' || element.type === 'radio') {
        element.checked = data.getAll(element.name).includes(element.value)
        continue
      }
      const value = data.getAll(element.name)[nth(element.name)]
      if (typeof value === 'string') element.value = value
    } else if (element instanceof HTMLTextAreaElement) {
      if (!element.name || element.disabled) continue
      const value = data.getAll(element.name)[nth(element.name)]
      if (typeof value === 'string') element.value = value
    } else if (element instanceof HTMLSelectElement) {
      if (!element.name || element.disabled) continue
      const values = data.getAll(element.name).map(String)
      for (const option of Array.from(element.options)) option.selected = values.includes(option.value)
    }
  }
}
