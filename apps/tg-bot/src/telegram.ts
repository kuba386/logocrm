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
  message?: { chat: { id: number }; text?: string }
  callback_query?: { id: string; data?: string; message?: { chat: { id: number } } }
}
