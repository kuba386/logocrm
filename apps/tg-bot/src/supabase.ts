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

// Поле и присваивание явно, не параметр-свойство конструктора: бот запускается
// `node --experimental-strip-types`, а он такой синтаксис не разбирает (падение
// при старте на Railway, 0071).
export class RpcError extends Error {
  readonly code: string | undefined

  constructor(message: string, code?: string) {
    super(message)
    this.code = code
  }
}
