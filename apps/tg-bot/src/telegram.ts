import { env } from './env.ts'

export type Button = { text: string; callback_data: string }

/**
 * Клавиатура под сообщением — или ForceReply: у человека сразу открывается
 * поле ввода с подсказкой (0071, заметка одним сообщением). Ответ на промпт
 * коррелируется по message_id промпта (0071 Р18в): бот привязывает его к
 * контексту через bot_bind_prompt, а reply_to_message из апдейта уходит в
 * bot_write_note.
 */
export type Reply = { buttons: Button[][] } | { forceReply: string }

/** Возвращает message_id отправленного сообщения (нужен для ForceReply). */
export async function sendMessage(chatId: number, text: string, reply?: Reply): Promise<number | null> {
  const replyMarkup =
    reply === undefined
      ? undefined
      : 'buttons' in reply
        ? { inline_keyboard: reply.buttons }
        : { force_reply: true, input_field_placeholder: reply.forceReply.slice(0, 64) }

  const response = await fetch(`https://api.telegram.org/bot${env.botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      reply_markup: replyMarkup,
    }),
  })
  const body = (await response.json().catch(() => null)) as { ok?: boolean; result?: { message_id?: number } } | null
  return body?.ok && typeof body.result?.message_id === 'number' ? body.result.message_id : null
}

/**
 * Убирает «часики» на нажатой кнопке — без этого она висит секунд десять.
 * alert=true — модалка, которую нужно закрыть: для отказов по деньгам и
 * подписке исчезающей плашки мало, человек решит, что кнопка не сработала.
 */
export async function answerCallback(id: string, text?: string, alert = false): Promise<void> {
  await fetch(`https://api.telegram.org/bot${env.botToken}/answerCallbackQuery`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ callback_query_id: id, text, show_alert: alert }),
  })
}

export type Update = {
  message?: {
    chat: { id: number }
    text?: string
    /** Подпись к фото/файлу — заметкой не становится (0071 Р14). */
    caption?: string
    /** Ответ на ForceReply-промпт заметки (0071 Р18в). */
    reply_to_message?: { message_id: number }
    /** Голосовое — диктовка резюме занятия (0041/0042). */
    voice?: { file_id: string; duration?: number }
    /**
     * Остальные вложения перечислены не ради обработки, а ради ответа:
     * специалист, приславший кружок или файл вместо голосового, должен
     * получить понятный текст, а не молчание.
     */
    audio?: unknown
    video_note?: unknown
    document?: unknown
    video?: unknown
    photo?: unknown
    sticker?: unknown
  }
  callback_query?: { id: string; data?: string; message?: { chat: { id: number } } }
}
