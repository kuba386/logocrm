import { rpc, RpcError } from './supabase.ts'
import { sendMessage, type Button } from './telegram.ts'

type TodayRow = {
  center_name: string
  lesson_id: string
  starts_at: string
  /** Время в поясе центра — считает база (0071 Р13), здесь не пересчитывается. */
  starts_local: string
  title: string
  teacher_name: string | null
  can_mark: boolean
  can_note: boolean
}

type BalanceRow = {
  center_name: string
  student_id: string
  full_name: string
  has_subscription: boolean
  lessons_left: number | null
  debt_tiyin: number
}

type Participant = { student_id: string; full_name: string; status_name: string | null }
type Status = { status_id: string; name: string }
type ActionKind = 'attendance' | 'note'

type ArmResult = {
  kind: ActionKind
  lesson_title: string
  student_id: string | null
  student_name: string | null
  students: Participant[]
  statuses: Status[] | null
  ttl_seconds: number
}
type PickResult = { kind: ActionKind; student_id: string; student_name: string; statuses: Status[] | null }
type MarkResult = { student_name: string; status_name: string; changed: boolean }
type NoteResult = { student_name: string; appended: boolean; preview: string }

export const HELP = 'Команды: /today — занятия на сегодня, /balance — остаток по детям.'

/** Деньги форматирует база (format_som); здесь — только тыйыны из payload. */
function som(tiyin: number): string {
  const sign = tiyin < 0 ? '−' : ''
  const abs = Math.abs(tiyin)
  return `${sign}${Math.floor(abs / 100)},${String(abs % 100).padStart(2, '0')} сом`
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
  await sendMessage(chatId, `Аккаунт привязан. ${HELP}`)
}

export async function handleToday(chatId: number): Promise<void> {
  const rows = await rpc<TodayRow[]>('bot_today', { p_chat_id: chatId })

  if (rows.length === 0) {
    await sendMessage(chatId, 'На сегодня занятий нет.')
    return
  }

  const lines = rows.map((row) => `${row.starts_local} — ${row.title} (${row.teacher_name ?? '—'})`)

  // callback_data — один uuid с префиксом (38 байт из 64 разрешённых); второй
  // uuid (ребёнок) живёт в контексте чата в базе (0071 Р4). Родителю и
  // бухгалтеру база отдаёт false — кнопок у них нет.
  const buttons: Button[][] = rows
    .filter((row) => row.can_mark || row.can_note)
    .map((row) => {
      const cells: Button[] = []
      if (row.can_mark) cells.push({ text: `Отметить ${row.starts_local}`, callback_data: `m:${row.lesson_id}` })
      if (row.can_note) cells.push({ text: `Заметка ${row.starts_local}`, callback_data: `n:${row.lesson_id}` })
      return cells
    })

  await sendMessage(
    chatId,
    `Занятия на сегодня:\n${lines.join('\n')}`,
    buttons.length > 0 ? { buttons } : undefined,
  )
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

/** Разбивает кнопки по две в ряд — статусов четыре, детей в группе до восьми. */
function rowsOf(buttons: Button[]): Button[][] {
  const rows: Button[][] = []
  for (let i = 0; i < buttons.length; i += 2) rows.push(buttons.slice(i, i + 2))
  return rows
}

/**
 * Следующий шаг после armирования/выбора ребёнка: кнопки детей, кнопки
 * статусов или поле ввода заметки. Один код на оба входа, чтобы групповое и
 * индивидуальное занятие не разошлись в тексте.
 */
async function promptNextStep(
  chatId: number,
  kind: ActionKind,
  title: string,
  studentId: string | null,
  studentName: string | null,
  students: Participant[],
  statuses: Status[] | null,
): Promise<string> {
  if (!studentId) {
    const buttons = students.map((s) => ({
      text: s.status_name ? `${s.full_name} (${s.status_name})` : s.full_name,
      callback_data: `p:${s.student_id}`,
    }))
    await sendMessage(chatId, `${title}: кого?`, { buttons: rowsOf(buttons) })
    return 'Выберите ребёнка'
  }

  if (kind === 'attendance') {
    const buttons = (statuses ?? []).map((s) => ({ text: s.name, callback_data: `a:${s.status_id}` }))
    await sendMessage(chatId, `${studentName}: статус посещения`, { buttons: rowsOf(buttons) })
    return 'Выберите статус'
  }

  const promptId = await sendMessage(
    chatId,
    `Заметка про ${studentName} — напишите одним сообщением. Окно — 3 минуты, ` +
      'черновик утверждается на экране занятия.',
    { forceReply: `Заметка про ${studentName}` },
  )
  // Р18в: ответ на устаревший промпт база отвергнет — только если знает,
  // какой промпт живой. Без message_id (сбой Telegram) окно работает без
  // корреляции, как обычное сообщение.
  if (promptId !== null) {
    // Промпт уже висит в чате: если привязка не удалась, текст всё равно
    // примется без корреляции — модалка «нет активной заметки» тут ложь.
    await rpc('bot_bind_prompt', { p_chat_id: chatId, p_message_id: promptId }).catch(() => undefined)
  }
  return 'Напишите заметку'
}

/** Кнопка «Отметить» / «Заметка» под занятием в /today. */
export async function handleArm(chatId: number, kind: ActionKind, lessonId: string): Promise<string> {
  const r = await rpc<ArmResult>('bot_arm_action', { p_chat_id: chatId, p_kind: kind, p_lesson_id: lessonId })
  return promptNextStep(chatId, r.kind, r.lesson_title, r.student_id, r.student_name, r.students, r.statuses)
}

/** Кнопка с ребёнком на групповом занятии. */
export async function handlePick(chatId: number, studentId: string): Promise<string> {
  const r = await rpc<PickResult>('bot_pick_student', { p_chat_id: chatId, p_student_id: studentId })
  return promptNextStep(chatId, r.kind, r.student_name, r.student_id, r.student_name, [], r.statuses)
}

/** Кнопка со статусом посещения. */
export async function handleStatus(chatId: number, statusId: string): Promise<string> {
  const r = await rpc<MarkResult>('bot_mark_attendance', { p_chat_id: chatId, p_status_id: statusId })
  const text = r.changed
    ? `${r.student_name}: ${r.status_name} — отмечено`
    : `${r.student_name}: ${r.status_name} — уже было отмечено`
  await sendMessage(chatId, text)
  return r.changed ? 'Отмечено' : 'Уже отмечено'
}

/**
 * Текст без «/» — заметка, если чат её ждёт. Если не ждёт (42704) — обычная
 * подсказка про команды: родитель, написавший «мы опоздаем», не должен
 * получать инструкцию к функции, которой у него нет (0071, ревью п. 12).
 */
export async function handleText(chatId: number, text: string, replyTo: number | null): Promise<void> {
  try {
    const r = await rpc<NoteResult>('bot_write_note', { p_chat_id: chatId, p_text: text, p_reply_to: replyTo })
    const tail = r.appended ? ' Дописано к черновику.' : ''
    // Родителю уходит только резюме, написанное человеком на экране (0047
    // Р3) — бот его не пишет, поэтому «допишите и утвердите», а не «утвердите».
    await sendMessage(
      chatId,
      `Записал про ${r.student_name}: «${r.preview}${text.trim().length > r.preview.length ? '…' : ''}».` +
        `${tail} Это черновик — резюме для родителя допишите и утвердите на экране занятия.`,
    )
  } catch (error) {
    if (error instanceof RpcError && error.code === '42704') {
      await sendMessage(chatId, HELP)
      return
    }
    throw error
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
