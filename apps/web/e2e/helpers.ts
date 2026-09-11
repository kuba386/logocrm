import { type Locator, type Page, expect } from '@playwright/test'

/**
 * Находит <select> по одному из его вариантов.
 *
 * Селект ученика в разметке без связанного <label> — по имени его не взять.
 * Поиск по варианту заодно устойчив к переименованию подписи: тест
 * привязан к данным, а не к оформлению.
 */
export function selectWithOption(page: Page, optionText: string): Locator {
  return page.locator('select', {
    has: page.locator('option', { hasText: optionText }),
  }).first()
}

/** Открывает неделю, в которую попадает дата (YYYY-MM-DD). */
export async function openWeek(page: Page, isoDate: string) {
  await page.goto(`/app/schedule?week=${isoDate}`)
  await expect(page.getByRole('heading', { name: 'Расписание' })).toBeVisible()
}

/**
 * Вчерашняя дата по Бишкеку (UTC+6, без перехода на летнее время —
 * фиксированный сдвиг безопасен). Занятия Данияра в фикстуре (e2e.sql)
 * датированы вчера по Бишкеку, не сегодня — см. комментарий там же.
 * Используется и для навигации по неделе расписания, и для явной даты
 * начала абонемента при продаже: одна и та же точка отсчёта, а не две
 * независимо вычисленные "сегодня"/"вчера", которые могли бы разойтись.
 */
export function bishkekYesterdayIso(): string {
  const d = new Date(Date.now() + 6 * 60 * 60 * 1000)
  d.setUTCDate(d.getUTCDate() - 1)
  return d.toISOString().slice(0, 10)
}

export async function openBishkekYesterdayWeek(page: Page) {
  await openWeek(page, bishkekYesterdayIso())
}

/** Карточки занятий ученика на открытой неделе, в порядке рендера сетки. */
export function studentCards(page: Page, student: string): Locator {
  return page.locator('button').filter({ hasText: student })
}

export type LessonForm = {
  service: string
  /** Специалист выбирается всегда явно: диалог по умолчанию берёт первого
   *  по алфавиту, и в фикстуре это Айгуль, а не Нургуль. */
  teacher: string
  student: string
  room?: string
  firstDay: string
  until?: string
  time: string
  /** Подписи кнопок дней недели: Пн, Вт, Ср… */
  weekdays: string[]
}

/** Открывает и заполняет диалог создания. Отправку делает сам тест. */
export async function fillLessonDialog(page: Page, form: LessonForm) {
  // Кнопки дней недели — переключатели, а форма переживает закрытие диалога.
  // Без перезагрузки второй вызов подряд СНИМАЕТ уже выбранный день вместо
  // того, чтобы выбрать его, и тест падает с «Выберите хотя бы один день
  // недели» — по причине, не имеющей отношения к проверяемому поведению.
  await page.reload()
  await page.getByRole('button', { name: 'Добавить занятие' }).click()

  await selectWithOption(page, form.service).selectOption({ label: form.service })
  await page.getByLabel('Специалист', { exact: true }).selectOption({ label: form.teacher })
  await selectWithOption(page, form.student).selectOption({ label: form.student })

  if (form.room) {
    await selectWithOption(page, form.room).selectOption({ label: form.room })
  }

  await page.getByLabel('Первый день').fill(form.firstDay)
  if (form.until) await page.getByLabel('Повторять до').fill(form.until)
  await page.getByLabel('Время').fill(form.time)

  for (const day of form.weekdays) {
    await page.getByRole('button', { name: day, exact: true }).click()
  }
}

/** Карточка занятия в недельной сетке. */
export function lessonCard(page: Page, time: string, student: string): Locator {
  return page.locator('button', { hasText: time }).filter({ hasText: student }).first()
}

/** Сколько занятий показано на текущей неделе — из подписи над сеткой. */
export async function lessonsThisWeek(page: Page): Promise<number> {
  const text = await page.getByText(/Занятий на неделе: \d+/).innerText()
  return Number(text.match(/(\d+)/)![1])
}

/**
 * Отправляет диалог создания и ждёт ответа сервера.
 *
 * Ждать закрытия диалога нельзя: после успеха он остаётся открытым и лишь
 * показывает уведомление. И уходить со страницы сразу после click() тоже
 * нельзя — server action ещё выполняется, переход прервал бы запрос, а тест
 * упал бы позже на счётчике занятий, где причина уже не видна.
 *
 * Уведомление — единственный признак, что сервер ответил успехом.
 */
export async function submitLessonDialog(page: Page, expectedNotice: string | RegExp) {
  await page.getByRole('button', { name: 'Создать' }).click()
  await expectServerReply(page, expectedNotice)
}

/**
 * Ждёт ответа сервера и падает внятно, если он оказался отказом.
 *
 * Без этого отказ выглядел как двадцать секунд ожидания уведомления и
 * «element(s) not found» — по такому сообщению не видно, что сервер вообще
 * ответил, и чем именно.
 */
async function expectServerReply(page: Page, expectedNotice: string | RegExp) {
  const notice = page.getByRole('status')
  // Служебный <div role="alert" id="__next-route-announcer__"> Next.js
  // обычно пуст, но после клиентской навигации (Link, без полной
  // перезагрузки) на миг держит заголовок новой страницы для скринридера —
  // тогда фильтр по «непустому тексту» его не отсекает, и тест видит
  // «отказ» вида «Карточка ученика — LogoCRM». Исключаем по id, а не по
  // содержимому: оно то пустое, то нет, а id всегда один и тот же.
  const error = page.locator('[role="alert"]:not(#__next-route-announcer__)').filter({ hasText: /\S/ })

  await expect(notice.or(error).first()).toBeVisible({ timeout: 20_000 })

  if (await error.first().isVisible()) {
    throw new Error(
      `Сервер отказал вместо ожидаемого «${expectedNotice}»: ${await error.first().innerText()}`,
    )
  }

  await expect(notice).toContainText(expectedNotice)
}

/** Нажимает кнопку действия и ждёт уведомления сервера — та же причина. */
export async function actAndAwait(page: Page, button: string | RegExp, expectedNotice: string | RegExp) {
  await page.getByRole('button', { name: button }).click()
  await expectServerReply(page, expectedNotice)
}
