import { createServer } from 'node:http'
import { env } from './env.ts'
import { handleBalance, handleConfirm, handleStart, handleToday, handleVoice } from './commands.ts'
import { answerCallback, sendMessage, type Update } from './telegram.ts'
import { RpcError } from './supabase.ts'

/**
 * Вебхук Telegram. Никакой библиотеки: команд три и одна кнопка, а лишняя
 * зависимость в отдельно деплоимом сервисе — лишний повод его чинить.
 * Отступление от промта этапа, где предполагался grammY.
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
  if (message && (message.audio || message.video_note || message.document || message.video)) {
    await sendMessage(
      message.chat.id,
      'Нужно голосовое сообщение — то, что записывается кнопкой с микрофоном. ' +
        'Кружки и файлы я не расшифровываю.',
    )
    return
  }

  if (message?.text) {
    const chatId = message.chat.id
    const [command, argument] = message.text.trim().split(/\s+/, 2)

    try {
      if (command === '/start') await handleStart(chatId, argument)
      else if (command === '/today') await handleToday(chatId)
      else if (command === '/balance') await handleBalance(chatId)
      else await sendMessage(chatId, 'Команды: /today — занятия на сегодня, /balance — остаток по детям.')
    } catch (error) {
      // Текст исключения из базы уже по-русски — показываем его, а не «500».
      await sendMessage(chatId, error instanceof RpcError ? error.message : 'Не получилось, попробуйте позже')
    }
    return
  }

  const callback = update.callback_query
  if (callback?.data && callback.message) {
    const answer = await handleConfirm(callback.message.chat.id, callback.data)
    await answerCallback(callback.id, answer)
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
    // атомарно, подтверждение идемпотентно (0033).
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
