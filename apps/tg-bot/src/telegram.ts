import { env } from './env.ts'

type Button = { text: string; callback_data: string }

export async function sendMessage(
  chatId: number,
  text: string,
  buttons?: Button[][],
): Promise<void> {
  await fetch(`https://api.telegram.org/bot${env.botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      reply_markup: buttons ? { inline_keyboard: buttons } : undefined,
    }),
  })
}

/** Убирает «часики» на нажатой кнопке — без этого она висит секунд десять. */
export async function answerCallback(id: string, text?: string): Promise<void> {
  await fetch(`https://api.telegram.org/bot${env.botToken}/answerCallbackQuery`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ callback_query_id: id, text }),
  })
}

export type Update = {
  message?: {
    chat: { id: number }
    text?: string
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
  }
  callback_query?: { id: string; data?: string; message?: { chat: { id: number } } }
}
