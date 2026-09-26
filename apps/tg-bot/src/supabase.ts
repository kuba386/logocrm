import { env } from './env.ts'

/**
 * Вызов RPC через PostgREST. Клиентской библиотеки здесь нет намеренно:
 * боту нужны девять функций, и одна зависимость ради них не окупается.
 */
export async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${env.supabaseUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: env.publishableKey,
      Authorization: `Bearer ${env.botJwt}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  })

  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as { message?: string; code?: string } | null
    // Текст исключения из базы уже по-русски (правило проекта) — его и
    // показываем пользователю, а не «Ошибка 400». Код SQLSTATE нужен, чтобы
    // отличить «нет контекста заметки» (42704) от остального (0071).
    throw new RpcError(body?.message ?? `Ошибка базы (${response.status})`, body?.code)
  }

  return (await response.json()) as T
}

export class RpcError extends Error {
  constructor(
    message: string,
    readonly code?: string,
  ) {
    super(message)
  }
}
