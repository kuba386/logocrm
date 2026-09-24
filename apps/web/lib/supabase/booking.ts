import 'server-only'
import { createClient as createSupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@logocrm/db'
import { supabaseEnv } from '@/lib/env'

/**
 * Клиент публичной витрины записи /book/[slug] (0057) — роль public_booking
 * (JWT без sub, claim role: public_booking), не anon и не service_role: тот
 * же довод, что у bot_worker (ADR-008) — утечка service_role открыла бы все
 * таблицы, а anon-ключ живёт в браузерном бандле. Секрет читается только
 * здесь, только на сервере (Server Actions/Server Components) — 'server-only'
 * ломает сборку, если модуль случайно попадёт в клиентский компонент.
 */
export function createBookingClient() {
  const { url, anonKey } = supabaseEnv()
  const jwt = process.env.SUPABASE_BOOKING_JWT

  if (!jwt) {
    throw new Error(
      'Не задана переменная окружения SUPABASE_BOOKING_JWT — публичная запись недоступна. JWT роли public_booking заводит владелец вручную (как SUPABASE_BOT_JWT у бота).',
    )
  }

  return createSupabaseClient<Database>(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
}
