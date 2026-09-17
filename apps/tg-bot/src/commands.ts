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
    timeZone: 'UTC',
  })
}

export async function handleStart(chatId: number, code: string | undefined): Promise<void> {
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

  // Время отдаёт база уже в поясе центра — здесь только форматирование,
  // поэтому timeZone: 'UTC' (иначе хостинг подвинул бы час второй раз).
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
  // callback_data: confirm:<lesson_id>:<student_id> — ребёнок обязателен,
  // у родителя может быть двое детей в одной группе (0033 Р6).
  const [, lessonId, studentId] = payload.split(':')
  if (!lessonId || !studentId) return 'Не удалось разобрать кнопку'

  try {
    const created = await rpc<boolean>('confirm_lesson', {
      p_chat_id: chatId,
      p_lesson_id: lessonId,
      p_student_id: studentId,
    })
    return created ? 'Спасибо, отметили' : 'Уже подтверждено'
  } catch (error) {
    return error instanceof RpcError ? error.message : 'Не удалось подтвердить'
  }
}
