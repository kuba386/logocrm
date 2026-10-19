'use server'

import { revalidatePath } from 'next/cache'
import { isCenterKind } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'

export type ModulesState = { message?: string; notice?: string }

const MODULE_TITLES: Record<string, string> = { clinic: 'Клиника', academic: 'Учёба' }

/** Включить или выключить модуль — set_center_module (0104): только владелец, readonly — отказ. */
export async function setCenterModule(code: string, enabled: boolean, _prev: ModulesState): Promise<ModulesState> {
  if (!(code in MODULE_TITLES)) return { message: 'Модуль не найден' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_center_module', { p_code: code, p_enabled: enabled })
  if (error) return toAppError(error, 'Не удалось изменить модуль')

  revalidatePath('/app', 'layout')
  return { notice: `Модуль «${MODULE_TITLES[code]}» ${enabled ? 'включён' : 'выключен'}` }
}

/** Сменить тип центра — set_center_kind (0104): меняет слова интерфейса, модули и данные не трогает. */
export async function setCenterKind(_prev: ModulesState, formData: FormData): Promise<ModulesState> {
  const kind = String(formData.get('kind') ?? '')
  if (!isCenterKind(kind)) return { message: 'Выберите тип центра' }

  const supabase = await createClient()
  const { error } = await supabase.rpc('set_center_kind', { p_kind: kind })
  if (error) return toAppError(error, 'Не удалось сменить тип центра')

  revalidatePath('/app', 'layout')
  return { notice: 'Тип центра сохранён' }
}
