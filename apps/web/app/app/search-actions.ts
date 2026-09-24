'use server'

import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'

export type SearchKind = 'student' | 'payer' | 'lesson' | 'group'

export type SearchRow = {
  kind: SearchKind
  id: string
  title: string
  subtitle: string | null
  extra: string | null
  status: string | null
  startsAt: string | null
  weekStart: string | null
  rank: number
}

const KINDS: SearchKind[] = ['student', 'payer', 'lesson', 'group']

/**
 * Глобальный поиск (0062): один вызов global_search — SECURITY INVOKER, роль
 * режет RLS. Здесь ничего не фильтруется и не считается: ни телефон, ни
 * права (CLAUDE.md — «права в браузере не считаются»).
 */
export async function globalSearch(query: string): Promise<{ rows: SearchRow[]; error?: string }> {
  const q = query.trim()
  if (q.length < 2) return { rows: [] }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('global_search', { p_query: q, p_limit: 6 })
  if (error) return { rows: [], error: toAppError(error, 'Поиск не удался').message }

  const rows: SearchRow[] = (data ?? [])
    .filter((r): r is typeof r & { kind: SearchKind } => KINDS.includes(r.kind as SearchKind))
    .map((r) => ({
      kind: r.kind,
      id: r.id,
      title: r.title,
      subtitle: r.subtitle ?? null,
      extra: r.extra ?? null,
      status: r.status ?? null,
      startsAt: r.starts_at ?? null,
      weekStart: r.week_start ?? null,
      rank: r.rank ?? 2,
    }))
  return { rows }
}
