import { rpc, RpcError } from './supabase.ts'
import { sendMessage } from './telegram.ts'

type TodayRow = {
  center_name: string
  lesson_id: string
  starts_at: string
  title: string
  teacher_name: string | null
}

type BalanceRow = {
  center_name: string
  student_id: string
  full_name: string
  has_subscription: boolean
  lessons_left: number | null
  debt_tiyin: number
}

/** Деньги форматирует база (format_som); здесь — только тыйыны из payload. */
function som(tiyin: number): string {
  const sign = tiyin < 0 ? '−' : ''
  const abs = Math.abs(tiyin)
  return `${sign}${Math.floor(abs / 100)},${String(abs % 100).padStart(2, '0')} сом`
}

function time(iso: string): string {
  return new Date(iso).toLocaleTimeString('ru-RU', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'Asia/Bishkek',
  })
}

/**
 * Голосовое длиннее этого не берём. Bot API не отдаёт файлы больше 20 МБ, у
 * Whisper предел 25 МБ — длинная диктовка упала бы на скачивании, то есть
 * уже после гашения токена и записи события. Отбить в боте дешевле: токен
 * остаётся живым, специалист просто говорит короче.
 */
const MAX_VOICE_SECONDS = 15 * 60

/** Префикс deep-link «записать резюме»: t.me/<bot>?start=voice_<токен>. */
const VOICE_PREFIX = 'voice_'

export async function handleStart(chatId: number, code: string | undefined): Promise<void> {
  // Ветвление до link_telegram: иначе токен диктовки уходит в привязку
  // аккаунта, и специалист по собственной кнопке получает «код
  // недействителен».
  if (code?.startsWith(VOICE_PREFIX)) {
    const armed = await rpc<{ student_name: string | null }>('arm_voice_request', {
      p_token: code.slice(VOICE_PREFIX.length),
      p_chat_id: chatId,
    })
    await sendMessage(
      chatId,
      `Записываю резюме про ${armed.student_name ?? 'ребёнка'}. ` +
        'Отправьте голосовое сообщение одним куском.',
    )
    return
  }

  if (!code) {
    await sendMessage(
      chatId,
      'Чтобы привязать аккаунт, откройте LogoCRM → раздел «Telegram» → «Получить код» ' +
        'и отправьте его сюда командой /start с кодом.',
    )
    return
  }

  await rpc('link_telegram', { p_code: code, p_chat_id: chatId })
  await sendMessage(
    chatId,
    'Аккаунт привязан. /today — занятия на сегодня, /balance — остаток по детям.',
  )
}

export async function handleToday(chatId: number): Promise<void> {
  const rows = await rpc<TodayRow[]>('bot_today', { p_chat_id: chatId })

  if (rows.length === 0) {
    await sendMessage(chatId, 'На сегодня занятий нет.')
    return
  }

  // bot_today отдаёт starts_at как настоящий timestamptz (честный UTC,
  // не сдвинутый в пояс центра — at time zone в SQL там только для
  // фильтра «сегодня»), поэтому здесь нужен явный часовой пояс центра,
  // а не UTC: иначе бот показывал бы время на 6 часов раньше реального.
  const lines = rows.map((row) => `${time(row.starts_at)} — ${row.title} (${row.teacher_name ?? '—'})`)
  await sendMessage(chatId, `Занятия на сегодня:\n${lines.join('\n')}`)
}

export async function handleBalance(chatId: number): Promise<void> {
  const rows = await rpc<BalanceRow[]>('bot_balance', { p_chat_id: chatId })

  if (rows.length === 0) {
    await sendMessage(chatId, 'Остаток показывается родителям. Если вы родитель — напишите администратору центра.')
    return
  }

  const lines = rows.map((row) => {
    // lessons_left = null значит и «безлимит», и «нет абонемента»;
    // различает их has_subscription (0010).
    const left = !row.has_subscription
      ? 'абонемента нет'
      : row.lessons_left === null
        ? 'безлимит'
        : `осталось ${row.lessons_left}`
    const debt = row.debt_tiyin > 0 ? `, долг ${som(row.debt_tiyin)}` : ''
    return `${row.full_name}: ${left}${debt}`
  })

  await sendMessage(chatId, lines.join('\n'))
}

export async function handleConfirm(chatId: number, payload: string): Promise<string> {
  // callback_data: c:<event_id>:<student_id>. Ребёнок обязателен — у родителя
  // может быть двое детей в одной группе (0033 Р6); занятие достаётся из
  // события, потому что пара uuid не помещается в лимит Telegram
  // в 64 байта (0035 Р2). Строку собирает SQL, здесь только разбор.
  const [prefix, eventId, studentId] = payload.split(':')
  if (prefix !== 'c' || !eventId || !studentId) return 'Не удалось разобрать кнопку'

  try {
    const created = await rpc<boolean>('confirm_lesson_by_event', {
      p_chat_id: chatId,
      p_event_id: Number(eventId),
      p_student_id: studentId,
    })
    return created ? 'Спасибо, отметили' : 'Уже подтверждено'
  } catch (error) {
    return error instanceof RpcError ? error.message : 'Не удалось подтвердить'
  }
}


export async function handleVoice(
  chatId: number,
  fileId: string,
  duration: number | undefined,
): Promise<void> {
  if (duration !== undefined && duration > MAX_VOICE_SECONDS) {
    await sendMessage(
      chatId,
      `Голосовое длиннее ${MAX_VOICE_SECONDS / 60} минут я не обработаю — ` +
        'разбейте на части и отправьте первую. Запись всё ещё ждёт.',
    )
    return
  }

  // Гашение токена и создание задачи — одной транзакцией в базе (0041 Р10):
  // повторный апдейт от Telegram просто не найдёт активной записи.
  const accepted = await rpc<{ student_name: string | null }>('report_voice_note', {
    p_chat_id: chatId,
    p_file_id: fileId,
    p_duration: duration ?? null,
  })

  await sendMessage(
    chatId,
    `Принял запись про ${accepted.student_name ?? 'ребёнка'}. ` +
      'Черновик придёт сюда же, обычно меньше чем за минуту.',
  )
}
