import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'
import type { Database } from '@logocrm/db'
import { supabaseEnv } from '@/lib/env'

export const dynamic = 'force-dynamic'

/**
 * Токен, которого не бывает: реальные — 48 случайных hex-символов (0004).
 * invitation_preview на неизвестный токен отвечает одной строкой
 * (null, null, false) без исключения — и это единственное, что anon вправе
 * вызвать до входа (pgTAP 0007 держит этот список ровно из одной функции;
 * у anon нет ни одного права ни на одну таблицу — 0024). Заводить ради
 * монитора вторую anon-функцию значило бы ослабить этот забор.
 */
const PROBE_TOKEN = '0'.repeat(48)

/**
 * Проверка живости для внешнего монитора (UptimeRobot, docs/OBSERVABILITY_SETUP.md).
 *
 * Публичный путь (PUBLIC_PATHS в middleware) — иначе monitor без сессии
 * получал бы редирект на /login вместо JSON. Ключ — публичный, не
 * service_role (ADR-008). Ответ ok только когда Postgres реально выполнил
 * запрос: invitation_preview ходит в invitations ⋈ centers, а не читает
 * кэш PostgREST. Наружу — ни одного поля из базы.
 */
export async function GET() {
  const { url, anonKey } = supabaseEnv()
  const supabase = createClient<Database>(url, anonKey, { auth: { persistSession: false } })

  try {
    const { data, error } = await supabase
      .rpc('invitation_preview', { p_token: PROBE_TOKEN })
      .abortSignal(AbortSignal.timeout(5000))

    if (error) {
      return NextResponse.json({ ok: false, error: error.message }, { status: 503 })
    }
    // Ровно одна строка с valid=false — иначе ответила не база, а что-то по пути.
    if (data?.length !== 1 || data[0]?.valid !== false) {
      return NextResponse.json({ ok: false, error: 'unexpected response' }, { status: 503 })
    }
    return NextResponse.json({ ok: true, ts: Date.now() })
  } catch (e) {
    const message = e instanceof Error ? e.message : 'unknown'
    return NextResponse.json({ ok: false, error: message }, { status: 503 })
  }
}
