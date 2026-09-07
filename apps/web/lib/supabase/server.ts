import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import type { Database } from '@logocrm/db'
import { supabaseEnv } from '@/lib/env'

/**
 * Supabase-клиент для server components, server actions и route handlers.
 * В Next 15 cookies() асинхронный — клиент создаётся через await.
 */
export async function createClient() {
  const cookieStore = await cookies()
  const { url, anonKey } = supabaseEnv()

  return createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options)
          }
        } catch {
          // Вызов из server component: куки уже отправлены.
          // Сессию в этом случае обновляет middleware.
        }
      },
    },
  })
}
