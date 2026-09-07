'use client'

import { createBrowserClient } from '@supabase/ssr'
import type { Database } from '@logocrm/db'
import { supabaseEnv } from '@/lib/env'

/** Supabase-клиент для клиентских компонентов. */
export function createClient() {
  const { url, anonKey } = supabaseEnv()
  return createBrowserClient<Database>(url, anonKey)
}
