# Этапы

Источник истины по плану работ. Архитектор пишет этапы, агент идёт по файлу
сам, владелец ставит `✅` после приёмки кликом.

Формат этапа: **Промт** (что делать), **Чек-лист** (что проверить кликом),
**Ручные шаги** (что владелец делает сам — секреты, тумблеры, prod).

**Перед UI-частью этапа — открой макет из `docs/Design/screens`.** Если его
там нет, сгенерируй экран в Stitch по описанию из промта этапа, сохрани
скриншот и ссылку, и только потом пиши код. HTML из Stitch не копируется:
переносятся структура и токены на shadcn/ui — [ADR-007](../Decisions/ADR-007-design-source.md).

| Этап | Что | Статус |
|---|---|---|
| 0 | Фундамент: тенант, роли, RLS, аудит, outbox | ✅ |
| 1 | Сотрудники и приглашения | ✅ |
| 2 | Ученики и плательщики | ✅ |
| 3 | Расписание | ✅ |
| 4 | Посещения и абонементы | ⬜ |
| 5 | Финансы и зарплата | ⬜ |
| 6 | Telegram-бот и n8n | ⬜ |
| 7 | Клиника: диагностика, цели, ДЗ, AI-резюме | ⬜ |
| 8 | SaaS: тарифы, лимиты, онбординг, prod | ⬜ |

---

## Этап 0 — фундамент ✅

Отчёт: [reports/stage-0.md](../../reports/stage-0.md) — не писался, этап шёл
до введения формата отчётов. Итог в [CHANGELOG](../CHANGELOG.md).

## Этап 1 — сотрудники и приглашения ✅

## Этап 2 — ученики и плательщики ✅

---

## Общие правила для агента

Действуют на каждом этапе:

- Перед началом прочитать `docs/Architecture.md`, `docs/Database.md`, все `docs/Decisions/*`, отчёт предыдущего этапа.
- Схема — только файлами миграций по конвенции из `docs/Database.md`. MCP — только чтение.
- Слои в порядке: миграция → pgTAP → `packages/core` (+Vitest) → `packages/contracts` → repo/actions → UI → `docs/Database.md`, `CHANGELOG`, ADR при решениях.
- Все тексты на русском. Деньги — integer в тыйынах. Никаких DELETE — `deleted_at`.
- Каждое бизнес-событие — `emit_event`. Типы событий — в `packages/contracts/events.ts`.
- В конце этапа: PR, дождаться CI и deploy-staging, пройти чек-лист кликом, записать `docs/Roadmap/reports/stage-N.md` по TEMPLATE (обязательно «Отступления от ТЗ» и «Что это даёт»).
- Останавливаться только на пунктах «Требует пользователя».

---

## Этап 3 — Расписание ✅

**Цель.** Админ создаёт занятия (индивидуальные и групповые), система не даёт накладок, препод видит только свои.

**Промт.**
```
Миграция 0006_schedule.sql:
1. rooms (кабинеты): id, center_id, name, capacity int default 1, is_active, + конвенции. apply_tenant_rls/apply_audit.
2. services (услуги): id, center_id, name, duration_min int not null default 45, default_price_tiyin int, kind text check in ('individual','group'), is_active. RLS/audit.
3. groups: id, center_id, name, service_id, teacher_id, room_id, max_students int, is_active. RLS/audit. group_students(group_id, student_id, joined_at, left_at) с RLS по центру группы.
4. lessons: id, center_id, service_id, teacher_id uuid not null, substitute_teacher_id, room_id, group_id (null = индивидуальное), student_id (для индивидуального), starts_at timestamptz not null, ends_at timestamptz not null, status text default 'planned' check in ('planned','done','cancelled'), cancel_reason text, series_id uuid (для повторов), notes, + конвенции. Check: (group_id is null) <> (student_id is null).
   EXCLUDE USING gist (teacher_id with =, tstzrange(starts_at, ends_at) with &&) where (deleted_at is null and status <> 'cancelled') — препод не может быть в двух местах. Аналогично для room_id и для student_id. Нужен btree_gist.
   RLS: tenant_admin; teacher_read_own: select если teacher_id = my_teacher_id() or substitute_teacher_id = my_teacher_id(); teacher_update_status: update только полей status/notes своих уроков (через отдельную функцию, не прямой update); parent_read: select уроков своих детей.
5. Расширить политику students.teacher_read_own_students: primary_teacher_id = my_teacher_id() OR exists(lessons где teacher_id = my_teacher_id() и student_id = students.id).
6. Функции: create_lesson_series(p jsonb) — создаёт повторяющиеся уроки по дням недели до даты, один series_id; cancel_lesson(id, reason); cancel_series_from(series_id, from_date, reason); substitute_teacher(lesson_id, new_teacher_id) → emit 'lesson.substituted'; teacher_vacation(teacher_id, from, to) — отмена уроков за период с reason 'vacation', emit 'teacher.vacation'.
7. События: lesson.created, lesson.cancelled, lesson.substituted, teacher.vacation.

pgTAP: накладка по преподу — исключение; накладка по кабинету — исключение; отменённый урок не блокирует слот; teacher видит только свои; teacher не может создать урок; родитель видит уроки только своих детей.

core: schedule.ts — generateSeriesDates(start, weekdays[], until, time), детект пересечений на клиенте для мгновенной подсказки. Тесты.

UI:
- /app/schedule — вид «Неделя» (колонки дни, строки полчаса) и «День». Фильтр по специалисту/кабинету. Клик по пустому слоту → Dialog создания: услуга, ученик или группа, специалист, кабинет, время, повтор (дни недели + до даты). При накладке — inline-ошибка с указанием, с чем пересекается.
- Клик по уроку → панель: детали, «Отменить» (причина), «Заменить специалиста», «Перенести» (drag-and-drop или смена времени).
- Для teacher — только свои уроки, только просмотр + кнопка «Провёл» / «Отменить» (через функцию).
- /app/settings/services, /app/settings/rooms, /app/groups — CRUD.
- Кнопка «Отпуск специалиста» в карточке teacher → teacher_vacation с предпросмотром списка отменяемых уроков.
- Меню: «Расписание» всем.
```

**Чек-лист.**
1. Создать 2 услуги, 1 кабинет, 2 специалиста. Индивидуальный урок пн 10:00 → второй тому же преподу пн 10:30 (45 мин) → ошибка накладки с текстом.
2. Серия ср+пт до конца месяца → уроки созданы, один series_id. Отмена серии с середины → отменены только будущие.
3. Замена специалиста → под новым преподом урок виден, под старым — нет.
4. Отпуск специалиста на неделю → предпросмотр 3 урока → все cancelled, reason vacation, событие.
5. Под teacher: расписание только своё, «Провёл» работает, создать урок невозможно (UI и SQL).
6. Родитель (пригласить с role parent) видит уроки только своего ребёнка.

**Требует пользователя.** Нет.

---

## Этап 4 — Посещения и абонементы ⬜

**Цель.** Отметка посещения одним кликом с автоматическим списанием, заморозка, долги, автопродление.

**Промт.**
```
Миграция 0007_attendance_subscriptions.sql:
1. attendance_statuses: id, center_id, code text, name text, color text, deducts_lesson bool, pays_teacher bool, counts_absence bool, notify_parent bool, is_default bool, sort int. RLS/audit. При create_center — seed 4 статуса: пришёл (deduct, pay), опоздал (deduct, pay), болел (no deduct, no pay, absence), прогул (deduct, pay, absence).
2. subscription_types: id, center_id, name, service_id, kind text check in ('lessons','period','unlimited'), lessons_count int, period_days int, price_tiyin int not null, is_active. RLS/audit.
3. subscriptions: id, center_id, student_id not null, payer_id not null, type_id, lessons_total int, lessons_used int default 0, price_tiyin int, lesson_price_tiyin int (расчётная = price/lessons, округление вниз), starts_at date, ends_at date, freeze_from date, freeze_to date, allow_negative bool default false, status text check in ('active','frozen','exhausted','expired','cancelled'), notes. RLS: admin; parent_read свои; teacher — не видит вообще.
4. attendance: id, center_id, lesson_id not null, student_id not null, status_id not null, subscription_id (что списали), marked_by, marked_at, comment. Unique(lesson_id, student_id). RLS: admin; teacher — select/insert/update на своих уроках (через функцию mark_attendance). audit.
5. Функция mark_attendance(lesson_id, student_id, status_code, comment): проверяет право (admin или teacher урока), выбирает активный абонемент ученика по услуге (ближайший к концу), если deducts_lesson — lessons_used+1, при lessons_used >= total → status exhausted; если абонемента нет и allow_negative у центра выключен — записывает attendance с subscription_id null и emit 'attendance.no_subscription'. Пометить lesson.status='done'. emit 'attendance.marked'. Массовая: mark_attendance_bulk(lesson_id, jsonb).
6. Функции: freeze_subscription(id, from, to) — сдвигает ends_at на длительность, status frozen, emit; unfreeze; transfer_remaining(from_sub, to_student) — перенос остатка; refund_calc(sub_id) → сумма возврата = остаток × lesson_price.
7. View student_balance: student_id, active_subscription_id, lessons_left, ends_at, debt_tiyin (сумма attendance без абонемента × цена услуги). Доступ admin + parent свои.
8. Триггер после mark_attendance: если lessons_left <= 2 → emit 'subscription.low_balance'; если 2 подряд counts_absence → emit 'student.absent_streak'.
9. События: attendance.marked, attendance.no_subscription, subscription.created, subscription.frozen, subscription.low_balance, subscription.exhausted, student.absent_streak.

pgTAP: teacher не видит subscriptions; mark_attendance чужого урока — исключение; списание уменьшает остаток; статус «болел» не списывает; freeze сдвигает ends_at; low_balance событие при остатке 2.

core: subscription.ts — lessonPrice, refundAmount, freezeShift, nextExpiry; тесты.

UI:
- В расписании: клик «Провёл» → панель отметки: для группы список учеников с кнопками статусов (цвета из attendance_statuses), для индивидуального — сразу статусы. Показывать остаток занятий рядом с именем, красным если 0.
- /app/students/[id] вкладка «Абонементы»: список, «Продать абонемент» (тип → цена подставляется, редактируемая), «Заморозить», «Перенести остаток», «Вернуть» (показывает расчёт). Вкладка «Посещения»: история.
- /app/settings/attendance-statuses и /app/settings/subscription-types — CRUD.
- /app/debts — список учеников с долгом/нулевым остатком, кнопки WhatsApp.
- Дашборд: карточки «Сегодня занятий», «Заканчиваются абонементы (≤2)», «Долги».
- Родитель: /app/my — дети, остаток, ближайшие занятия, история посещений.
```

**Чек-лист.**
1. Продать абонемент 8 занятий за 4 000 сом → lesson_price 500.00, остаток 8.
2. Отметить «пришёл» → остаток 7, lesson done. «Болел» → остаток не меняется. Два «прогул» подряд → событие absent_streak.
3. Заморозить на 7 дней → ends_at +7, статус frozen; отметить посещение во время заморозки — исключение.
4. Довести остаток до 2 → событие low_balance; до 0 → exhausted; отметить ещё → attendance без абонемента, долг в /app/debts.
5. Под teacher: отметка работает, `select * from subscriptions` → 0 строк, остаток в UI виден числом (через student_balance? — нет: teacher видит только «есть/нет абонемента», без сумм — проверить).
6. Под parent: /app/my показывает остаток своего ребёнка, чужого — нет.

**Требует пользователя.** Нет.

---

## Этап 5 — Финансы и зарплата ⬜

**Цель.** Платежи, источники, замок месяца, расчёт зарплаты по проведённым занятиям.

**Промт.**
```
Миграция 0008_finance.sql:
1. payment_sources: id, center_id, name (наличные, Mbank, O!Dengi, Elcart, перевод), is_active, sort. Seed при create_center. RLS admin.
2. payments: id, center_id, payer_id not null, student_id, subscription_id, amount_tiyin int not null, source_id, paid_at timestamptz default now(), kind text check in ('payment','refund','correction'), comment, + конвенции. RLS admin only; parent — select свои. audit.
3. expenses: id, center_id, category text, amount_tiyin, paid_at, comment. RLS admin.
4. financial_periods: center_id, month date (первое число), closed_at, closed_by. Триггер на payments/expenses/attendance: запрет insert/update/delete если дата попадает в закрытый месяц (кроме kind='correction' с датой текущего месяца).
5. Расширить subscriptions: paid_tiyin int default 0; триггер на payments обновляет; status частичной оплаты в view.
6. installments (рассрочка): subscription_id, due_date, amount_tiyin, paid_at. Функция create_installment_plan(sub_id, n, first_date). Событие 'installment.due' — cron-функция помечает просроченные, emit.
7. teacher_rates: teacher_id, service_id (null = все), model text check in ('per_lesson','per_hour','percent_payment','per_student'), value int (тыйыны или проценты×100), valid_from. RLS admin; teacher — select свои.
8. salary_lines view/функция calc_salary(teacher_id, month): по attendance с pays_teacher=true и lessons.status='done', по ставке на дату; итог + детализация. salary_adjustments (бонус/штраф): teacher_id, month, amount_tiyin, reason.
9. Views: revenue_by_month, revenue_by_teacher, revenue_by_service, cash_by_source — admin only.
10. Функция close_month(month): проверки (нет уроков в planned за месяц), closed_at, emit 'period.closed'.
11. События: payment.received, payment.refunded, period.closed, salary.calculated, installment.due, installment.overdue.

pgTAP: teacher не видит payments; запись платежа в закрытый месяц — исключение; correction в открытый — ок; calc_salary считает только done + pays_teacher; parent видит свои платежи и не видит чужие.

core: salary.ts — модели расчёта, тесты на каждую; finance.ts — округления, частичная оплата.

UI:
- «Продать абонемент» из этапа 4 → сразу форма оплаты: сумма (по умолчанию полная), источник, дата; чекбокс «Рассрочка» → n платежей, даты.
- /app/finance: вкладки «Платежи» (таблица, фильтры, добавить платёж/возврат), «Расходы», «Рассрочки» (просроченные красным, WhatsApp), «Периоды» (замок месяца с предпросмотром незакрытых уроков).
- /app/salary: месяц → таблица по специалистам → раскрытие детализации → бонус/штраф → «Утвердить» (emit salary.calculated). Печать/PDF ведомости.
- /app/settings/teacher-rates — ставки.
- Дашборд admin: выручка месяц/план, касса по источникам, долги, рассрочки просроченные.
- Teacher: /app/my-salary — свой месяц, детализация, без чужих данных.
- Parent: /app/my → «Платежи» — история.
```

**Чек-лист.**
1. Продать абонемент 4 000, оплата 2 000 Mbank + рассрочка 2×1 000 → paid 2 000, 2 installments.
2. Ставка препода 300 сом/занятие → 5 «пришёл» + 1 «болел» → зарплата 1 500. Бонус 500 → 2 000. Под teacher — видит 2 000 и детализацию, /app/salary недоступна.
3. Закрыть прошлый месяц → добавить платёж датой прошлого месяца → ошибка; correction — ок.
4. Возврат по абонементу с остатком 3 → сумма = 3 × lesson_price, payment kind refund, subscription cancelled.
5. Просроченная рассрочка (дата вчера) → в списке красным, событие overdue.

**Требует пользователя.** Нет.

---

## Этап 6 — Telegram-бот и n8n ⬜

**Цель.** События из outbox превращаются в сообщения. Родитель и специалист получают уведомления в Telegram.

**Промт.**
```
Миграция 0009_notifications.sql:
1. telegram_accounts: user_id, chat_id bigint unique, linked_at. Функция link_telegram(code) — привязка по одноразовому коду из бота.
2. message_templates: center_id, event_type, channel ('telegram','whatsapp_link'), text (с плейсхолдерами {child}, {date}, {left}), is_active. Seed дефолтных RU шаблонов при create_center: lesson.reminder, subscription.low_balance, student.absent_streak, installment.due, homework.assigned, lesson.summary.
3. notification_log: center_id, event_id, recipient_user_id, channel, status, sent_at, error. RLS admin.
4. Функция dispatch_events() — pg_cron каждую минуту: непрочитанные events → POST на n8n webhook (url в centers.settings или глобальный из vault), помечает processed_at. Ретрай 3 раза, потом status failed + emit 'event.failed'.
5. Cron-функции: lesson.reminder (за 18 ч до starts_at, emit по каждому уроку), daily_digest (08:00 по центру → emit 'digest.daily' с JSON: уроки сегодня, low_balance, долги, просроченные рассрочки).

apps/tg-bot (grammY, отдельный деплой, service_role key в env): /start <code> → link_telegram; /today — уроки специалиста; /balance — родителю остаток; inline-кнопки «Подтвердить приход» для родителя за день до урока (пишет lesson_confirmations). Webhook-режим.

n8n (экспорт JSON в /n8n): Router — по event.type → подпроцессы: notify (шаблон → подстановка → Telegram по chat_id получателей; если нет chat_id — записать в notification_log 'no_channel' и показать в UI кнопку WhatsApp deep-link), digest → owner/admin в Telegram, event.failed → тебе (владельцу платформы).

UI:
- /app/settings/notifications — шаблоны по событиям, вкл/выкл, предпросмотр.
- /app/settings/integrations — статус n8n webhook, «Привязать Telegram» (показать код для /start).
- В карточке плательщика: бейдж «Telegram привязан / не привязан», кнопка «Отправить приглашение в бот» (deep-link t.me/bot?start=code через WhatsApp).
- /app/notifications — лог отправок с ошибками.
```

**Чек-лист.**
1. Owner привязывает Telegram → /today отвечает списком.
2. Родитель привязывает → урок завтра → за 18 ч приходит напоминание с кнопкой «Подтвердить» → нажатие видно в карточке урока.
3. Остаток 2 → родителю сообщение по шаблону; шаблон отредактирован → следующее сообщение с новым текстом.
4. Убить n8n на 5 минут → события копятся с processed_at null → включить → все доставлены, ничего не потеряно.
5. 08:00 → owner получает дайджест.
6. Родитель без Telegram → в notification_log 'no_channel', в UI кнопка WhatsApp с подставленным текстом.

**Требует пользователя.** Создать бота через @BotFather (токен → секрет `TELEGRAM_BOT_TOKEN`); n8n webhook URL → секрет; деплой tg-bot (Railway/Fly/VPS с Hermes) — токены вводишь ты.

---

## Этап 7 — Клиника: диагностика, цели, ДЗ, AI-резюме ⬜

**Цель.** То, чего нет ни у одного конкурента СНГ: прогресс ребёнка и AI-резюме занятия из голосового.

**Промт.**
```
Миграция 0010_clinical.sql:
1. diagnostics: student_id, date, teacher_id, conclusion text, sounds jsonb (по звукам: {"р": "искажение", "л": "отсутствие"}), speech_areas jsonb (звукопроизношение/фонематика/лексика/грамматика/связная речь — уровень 1–5), attachments jsonb, + конвенции. RLS: admin + teacher своих учеников (через ту же политику, что students) + parent read-only conclusion.
2. goals: student_id, area text, sound text, stage text check in ('isolated','syllables','words','phrases','speech','automated'), title, target_date, status ('active','achieved','paused'), created_by. goal_progress: goal_id, lesson_id, date, score int 0–100, note. RLS как diagnostics.
3. exercise_library: center_id (null = общая библиотека платформы), area, sound, stage, title, instructions text, media_url, age_from, age_to, tags text[]. RLS: общая читается всеми, своя — по центру.
4. homework: student_id, lesson_id, assigned_at, due_at, exercises jsonb (ids + свободный текст), status ('assigned','submitted','reviewed'), parent_note, teacher_feedback. homework_media: homework_id, storage_path, kind ('video','audio','photo'), uploaded_by. Storage bucket 'homework' с политикой по center_id в пути.
5. lesson_notes: lesson_id, teacher_id, raw_transcript text, soap jsonb {subjective, objective, assessment, plan}, parent_summary text, goals_touched jsonb, source ('voice','text','manual'), model text, tokens_in, tokens_out, cost_tiyin, status ('draft','approved'), approved_at. RLS: admin, teacher свои; parent — только parent_summary после approved.
6. ai_usage: center_id, kind, tokens, cost_tiyin, at — для тарификации. Функция check_ai_quota(center_id) по плану.
7. События: diagnostic.created, goal.achieved, homework.assigned, homework.submitted, lesson.summary_ready, lesson.summary_approved.

n8n: подпроцесс voice_summary: событие 'lesson.voice_received' (из tg-bot: специалист отправил голосовое с reply на урок или выбрал урок кнопкой) → скачать файл → Whisper (ru) → Claude (system prompt: логопед-ассистент, вход: транскрипт + цели ученика + прошлые 3 заметки; выход строгий JSON soap + parent_summary + goals_touched с score) → insert lesson_notes draft → emit summary_ready → специалисту в Telegram кнопки «Утвердить / Править». Аудио не хранить — удалить после транскрипта. Утверждение → parent_summary родителю по шаблону.

core: clinical.ts — прогресс по цели (среднее последних 5 score), следующий этап, тесты; prompt-builder для Claude с тестом на валидный JSON.

UI:
- Карточка ученика: вкладки «Диагностика» (карта звуков — сетка согласных с цветом статуса, кликом меняется), «Цели» (список по областям, прогресс-бар, график score по датам, кнопка «Достигнута»), «Домашние задания» (лента, медиа от родителей, фидбек), «Заметки занятий» (SOAP, кнопки утверждения).
- В панели урока после «Провёл»: «Записать резюме» → текстом или «Отправьте голосовое в бот, урок выбран» (deep-link). Черновик появляется через realtime.
- /app/library — библиотека упражнений с фильтрами, «Добавить в ДЗ».
- Родитель /app/my: прогресс ребёнка (звуки, цели), ДЗ с загрузкой видео (Storage, до 100 МБ), резюме занятий.
- /app/settings/ai — использование за месяц, лимит по тарифу.
- Отчёт родителю за месяц: кнопка «Сформировать» → HTML/PDF: посещения, цели, динамика, рекомендации → отправить в Telegram.
```

**Чек-лист.**
1. Диагностика: отметить «р» искажение, «л» отсутствие → карта звуков окрашена, событие.
2. Цель «р в слогах» → 3 занятия с score 40/60/80 → прогресс-бар и график.
3. Специалист отправляет голосовое в бот → через ≤60 с черновик SOAP в карточке урока → «Утвердить» → родителю summary в Telegram. Аудио в Storage отсутствует.
4. Родитель загружает видео ДЗ → специалист видит, пишет фидбек → родителю уведомление.
5. Под teacher чужого ребёнка — diagnostics/goals 0 строк. Под parent — только parent_summary, raw_transcript недоступен.
6. Отчёт за месяц сформирован и отправлен.

**Требует пользователя.** Ключи OpenAI (Whisper) и Anthropic → секреты n8n.

---

## Этап 8 — SaaS: тарифы, лимиты, онбординг, prod ⬜

**Цель.** Продукт можно продавать: тарифы, ограничения, оплата подписки, prod-окружение.

**Промт.**
```
Миграция 0011_saas.sql:
1. plans: code, name, price_som_month int, limits jsonb {teachers, students, ai_notes_month, telehealth bool, branches}, features text[]. Seed: solo 2000, studio 5000, ai 10000 (уточнить у владельца).
2. centers: plan_expires_at, billing_email, invoices jsonb. platform_payments: center_id, amount, source, paid_at, months. Функция extend_subscription.
3. Триггеры лимитов: teachers (active count), students (active), ai_usage — исключение с понятным русским текстом «Тариф Solo: 1 специалист. Перейдите на Studio».
4. Trial: 14 дней, за 3 дня — emit 'trial.ending', по истечении — read-only режим (RLS: with check false для не-owner, баннер).
5. Мультифилиал: branches (center_id, name, address); lessons/rooms/teachers.branch_id nullable; фильтр в расписании. Только план studio+.
6. Экспорт данных центра: функция export_center() → JSON всех таблиц центра (admin), кнопка в настройках. Удаление центра: deleted_at + очистка через 30 дней (cron).
7. Публичная витрина записи: /book/[slug] — родитель выбирает услугу, специалиста, слот → lead в students(status lead) + lesson planned → уведомление админу. Rate limit.

UI:
- /app/settings/plan — текущий план, лимиты с прогрессом, «Сменить план», история платежей, «Оплатить» (реквизиты Mbank/Elcart QR + загрузка чека → владельцу платформы в Telegram → extend_subscription вручную; автоматика — позже).
- Баннеры trial/expired. Onboarding-чеклист на дашборде: добавить специалиста → услугу → ученика → урок → отметить посещение (галочки).
- Лендинг (перенести из старого репо) → apps/landing или /(marketing), CTA → регистрация.
- /admin (роль platform_admin в отдельной таблице platform_admins по user_id): список центров, план, оплата, продлить, MRR.

Prod:
- Новый Supabase проект `logocrm-prod`, регион Frankfurt, без seed. Confirm email ON, Leaked Password Protection ON, MFA для owner, PITR/бэкапы.
- GitHub Environment `production` с секретами и required reviewers (владелец). Workflow deploy-prod.yml — только вручную (workflow_dispatch) + подтверждение.
- Vercel: два проекта (staging/prod) или один с environments; домен.
- Sentry DSN, n8n prod instance, tg-bot prod.
- ADR-007-production-checklist.md с чеклистом из ADR-004 + этот список.
```

**Чек-лист.**
1. План solo → добавить второго специалиста → русская ошибка про тариф. Сменить на studio → ок.
2. Trial истёк (подкрутить дату) → баннер, teacher не может отметить посещение, owner видит «Оплатить».
3. Загрузить чек → владельцу платформы в Telegram → продлить в /admin → баннер исчез.
4. /book/slug → запись → lead + planned lesson + уведомление админу.
5. Экспорт центра → JSON со всеми таблицами; удалить тестовый центр → deleted_at, данные недоступны через API.
6. Prod: регистрация реального центра → приглашение специалиста → урок → посещение → SOAP из голосового. Sentry ловит тестовую ошибку.

**Требует пользователя.** Создание prod-проекта Supabase, секреты `production`, домен, Vercel, ключи Sentry, финальные цены тарифов, ручной deploy-prod.

---

## После этапа 8

Backlog из `docs/Backlog.md` → этапы 9+. Кандидаты: телетерапия (WebRTC), приложение специалиста (PWA), бенчмарки между центрами, автоматический приём оплаты подписки, кыргызский язык интерфейса.
