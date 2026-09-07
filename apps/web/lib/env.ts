/** Переменные окружения, нужные и на клиенте, и на сервере. */
export function supabaseEnv(): { url: string; anonKey: string } {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  // Новый формат ключа — sb_publishable_...; NEXT_PUBLIC_SUPABASE_ANON_KEY
  // поддерживается для старых legacy-ключей (JWT) и локального supabase start.
  const anonKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

  if (!url || !anonKey) {
    throw new Error(
      'Не заданы NEXT_PUBLIC_SUPABASE_URL и NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY. Скопируйте .env.example в .env.local.',
    )
  }

  return { url, anonKey }
}

export function siteUrl(): string {
  return process.env.NEXT_PUBLIC_SITE_URL ?? 'http://127.0.0.1:3000'
}
