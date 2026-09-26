import { createServer } from 'node:http'
import { env } from './env.ts'
import {
  HELP,
  handleArm,
  handleBalance,
  handleConfirm,
  handlePick,
  handleStart,
  handleStatus,
  handleText,
  handleToday,
  handleVoice,
} from './commands.ts'
import { answerCallback, sendMessage, type Update } from './telegram.ts'
import { RpcError } from './supabase.ts'

/**
 * Вебхук Telegram. Никакой библиотеки: три команды, четыре вида кнопок и
 * текст заметки — лишняя зависимость в отдельно деплоимом сервисе — лишний
 * повод его чинить. Отступление от промта этапа, где предполагался grammY.
 */
async function handleUpdate(update: Update): Promise<void> {
  const message = update.message

  if (message?.voice) {
    try {
      await handleVoice(message.chat.id, message.voice.file_id, message.voice.duration)
    } catch (error) {
      // Текст из базы уже по-русски: «Активной записи нет — нажмите
      // «Записать резюме» на экране занятия».
      await sendMessage(
        message.chat.id,
        error instanceof RpcError ? error.message : 'Не получилось принять запись, попробуйте ещё раз',
      )
    }
    return
  }

  // Кружок, аудиофайл или документ вместо голосового: ответить понятнее,
  // чем промолчать — специалист не поймёт, почему ничего не происходит.
  // Фото с подписью сюда же: подпись заметкой не становится (0071 Р14) —
  // и об этом сказано прямо, иначе в окне заметки ответ про микрофон
  // читается как поломка.
  if (
    message &&
    (message.audio ||
      message.video_note ||
      message.document ||
      message.video ||
      message.photo ||
      message.sticker)
  ) {
    await sendMessage(
      message.chat.id,
      'Нужно голосовое сообщение — то, что записывается кнопкой с микрофоном. ' +
        'Кружки и файлы я не расшифровываю.' +
        (message.caption ? ' Подпись к файлу заметкой не станет — пришлите её текстом.' : ''),
    )
    return
  }

  if (message?.text) {
    const chatId = message.chat.id
    const text = message.text.trim()

    try {
      if (!text.startsWith('/')) {
        // Заметка одним сообщением, если чат её ждёт (0071); иначе подсказка.
        await handleText(chatId, text, message.reply_to_message?.message_id ?? null)
        return
      }
      const [command, argument] = text.split(/\s+/, 2)
      if (command === '/start') await handleStart(chatId, argument)
      else if (command === '/today') await handleToday(chatId)
      else if (command === '/balance') await handleBalance(chatId)
      else await sendMessage(chatId, HELP)
    } catch (error) {
      // Текст исключения из базы уже по-русски — показываем его, а не «500».
      await sendMessage(chatId, error instanceof RpcError ? error.message : 'Не получилось, попробуйте позже')
    }
    return
  }

  const callback = update.callback_query
  if (callback?.data && callback.message) {
    const { answer, failed } = await handleCallback(callback.message.chat.id, callback.data)
    // Telegram показывает не больше 200 знаков; отказ — модалкой, чтобы его
    // нельзя было не заметить и нажать ещё раз.
    await answerCallback(callback.id, answer.slice(0, 200), failed)
  }
}

/**
 * Префиксы callback_data: c — подтверждение прихода родителем (0035),
 * m/n — «Отметить»/«Заметка» под занятием, p — ребёнок на групповом
 * занятии, a — статус посещения (0071). Строки собирает SQL, здесь разбор.
 */
async function handleCallback(chatId: number, data: string): Promise<{ answer: string; failed: boolean }> {
  const [prefix, id] = data.split(':', 2)
  if (prefix === 'c') return { answer: await handleConfirm(chatId, data), failed: false }
  if (!id) return { answer: 'Не удалось разобрать кнопку', failed: true }

  try {
    if (prefix === 'm') return { answer: await handleArm(chatId, 'attendance', id), failed: false }
    if (prefix === 'n') return { answer: await handleArm(chatId, 'note', id), failed: false }
    if (prefix === 'p') return { answer: await handlePick(chatId, id), failed: false }
    if (prefix === 'a') return { answer: await handleStatus(chatId, id), failed: false }
    return { answer: 'Не удалось разобрать кнопку', failed: true }
  } catch (error) {
    return {
      answer: error instanceof RpcError ? error.message : 'Не получилось, попробуйте позже',
      failed: true,
    }
  }
}

const server = createServer((request, response) => {
  if (request.method !== 'POST') {
    response.writeHead(405).end()
    return
  }

  // Открытый URL вебхука без этой проверки — чтение чужой семьи подбором
  // chat_id: функции бота доверяют chat_id из апдейта.
  if (request.headers['x-telegram-bot-api-secret-token'] !== env.webhookSecret) {
    response.writeHead(401).end()
    return
  }

  const chunks: Buffer[] = []
  request.on('data', (chunk: Buffer) => chunks.push(chunk))
  request.on('end', () => {
    // Telegram повторяет апдейт, если не ответить за секунды: отвечаем
    // сразу, обработку доигрываем в фоне. Повторы безопасны — гашение кода
    // атомарно, подтверждение идемпотентно (0033), контекст действия
    // сериализован по чату advisory lock'ом (0071 Р5).
    response.writeHead(200).end()

    let update: Update
    try {
      update = JSON.parse(Buffer.concat(chunks).toString('utf8')) as Update
    } catch {
      return
    }

    void handleUpdate(update).catch((error: unknown) => {
      console.error('Апдейт не обработан', error)
    })
  })
})

server.listen(env.port, () => {
  console.log(`tg-bot слушает :${env.port}`)
})
