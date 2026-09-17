/**
 * Все секреты — из окружения хостинга. В репозиторий не попадает ничего:
 * токен бота, секрет вебхука и JWT роли bot_worker вводит владелец.
 */
function required(name: string): string {
  const value = process.env[name]
  if (!value) throw new Error(`Не задана переменная окружения ${name}`)
  return value
}

export const env = {
  botToken: required('TELEGRAM_BOT_TOKEN'),
  /** Telegram шлёт его заголовком; чужой запрос на открытый URL отбивается. */
  webhookSecret: required('TELEGRAM_WEBHOOK_SECRET'),
  supabaseUrl: required('SUPABASE_URL'),
  /**
   * JWT с claim `role: bot_worker` — не service_role. У service_role
   * остаются все таблицы (0024 снимал гранты только у public/anon/
   * authenticated), и утечка такого ключа открыла бы карточки детей всех
   * центров мимо узких функций (ADR-008).
   */
  botJwt: required('SUPABASE_BOT_JWT'),
  port: Number(process.env.PORT ?? 8080),
}
