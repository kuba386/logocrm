# Этап 5 — Финансы и зарплата

Дата: 2026-09-12 (в работе)
PR: #32 (0013–0014), #35 (0016), #37 (0017), #38/#40/#44 (0018–0020), #43 (0021), #42/#45 (0022), далее — 0023+
Миграции: 0013_finance_core, 0014_finance_core_fixes, 0016_expenses, 0017_teacher_rates_and_salary, 0018_installments, 0019_installments_notify_archived, 0020_installment_plans, 0021_revenue_views, 0022_center_scoped_fks

## Plan

Раздел появился после начала этапа (правило «Перед этапом» — #41): бэкенд
пп.1–11 промта уже в `main`, ниже — что осталось, с теми же четырьмя
частями. Ретроспектива сделанного — в «Проверки» и «Найденные дефекты».

### 1. Что меняю

**Бэкенд, оставшееся:**

- `0023_sell_subscription_paid.sql` — RPC `sell_subscription_paid(p_type_id,
  p_student_id, p_sale_key, p_price_tiyin, p_starts_at, p_paid_tiyin,
  p_source_id, p_paid_on date, p_installments, p_first_due, p_step_months,
  p_expected_remaining_tiyin)` → таблица (subscription_id, payment_id,
  строки графика): `sell_subscription` + `record_payment` +
  `create_installment_plan` одной транзакцией. Существующие функции не
  меняются. Отказ любого шага откатывает всю продажу. Двойной клик —
  `subscriptions.sale_key` (частичный unique) + advisory-замок, не
  disabled на кнопке. Оплата без источника, дата в будущем, переплата —
  отказ. 0007 — белый список; `errors.ts` — `subscriptions_sale_key_key`.
  Architect по плану — 12 находок, по коду — второй раунд до PR.
- `0024_access_hygiene.sql` — долг грантов, найденный Advisors и ревью
  плана ролей (architect, 12 находок — учтены ниже):
  - **DELETE у `authenticated` так и висит** на таблицах 0001/0004/0005/
    0006 (`students`, `payers`, `rooms`, `services`, `groups`,
    `group_students`, `lessons`, `invitations`, `lesson_participants`,
    `audit_log`, `events`, `centers`) — default privileges Supabase, снимали
    только с таблиц 0008+. Сегодня его держит одна RLS (`tenant_admin` —
    `for all`): владелец прямым `DELETE /rest/v1/students` уносит ребёнка с
    каскадом по занятиям и посещениям без `deleted_at`. `revoke all … from
    anon, authenticated` + точечные `grant` в объёме исходных миграций
    (`select, insert, update` там, где было; `lesson_participants`,
    `audit_log`, `events`, `memberships` — только `select`; `centers` —
    `select, update`).
  - anon: `SELECT` по грантам на 17 объектах, включая `memberships` — не
    утечка (все политики `to authenticated`, вью `security_invoker`), а
    отсутствующий второй слой на случай будущей политики `to public`.
    Снимается вместе с DELETE; 4 вью 0004/0005 — `revoke all from anon,
    authenticated; grant select to authenticated`.
  - `memberships_select_self_or_admin` — `(select auth.uid())` (WARN
    `auth_rls_initplan`); остальные политики зовут `role_in(center_id)` по
    колонке строки — обернуть нельзя и не нужно.
  - **Последний владелец — триггер, не две функции.** `change_member_role` и
    `revoke_membership` считают владельцев в plpgsql, а `accept_invitation`
    делает `on conflict do update set role` мимо обеих: единственный
    владелец, кликнувший приглашение с ролью `parent` (после 0027 —
    правдоподобное `finance`), оставляет центр без владельца. Триггер
    `memberships_last_owner_guard` (before update or delete, 23514, тот же
    текст) + `accept_invitation` при существующем членстве — отказ 23505
    «Вы уже участник этого центра — роль меняет владелец», не перезапись
    роли по ссылке.
  - pgTAP: забор по каталогу без белых списков — `authenticated` без
    `DELETE` ни на одной таблице/вью `public`, anon без единого права;
    тест 0021 — белый список пустеет, вью вне списка 10; последний
    владелец через `accept_invitation`, второй владелец понижается.
- Роли `registrar` и `finance` («Доработка» п.1) — три миграции, три PR,
  **порядок инвертирован**: сначала RPC, последней — политики и лестница.
  Пока `memberships_role_check` не расширен, строка с новой ролью не
  существует, промежуточные состояния безопасны по построению.
  **Решение: `tenant_admin` не расширяется** — остаётся owner/admin; для
  новых ролей отдельные политики по явному списку таблиц; таблица без
  решения закрыта — этап 7 (диагностика, цели, ДЗ, `lesson_notes`) не
  достанется бухгалтеру по умолчанию.
  - `0025_roles_registrar_rpc.sql`: `memberships_role_check` и
    `invitations_role_check` += `registrar`, `finance` (лестница ещё не
    пускает — назначить нельзя, тесты сеют членство напрямую). Три
    предиката вместо литералов в каждом гейте — иначе обёртка и внутренняя
    функция разъедутся молча (`installment_plans_cancel_live` уже
    заблокировала бы обе роли): `can_front_desk(p_center uuid default
    current_center())` = owner/admin/registrar, `can_finance(...)` =
    owner/admin/finance, `can_payments(...)` = все четыре; `stable`,
    `coalesce(role_in(p_center), '')`. Перевыпуск с `can_front_desk()`:
    `create_student_with_payer`, `archive_student`, `restore_student`,
    `find_payer_by_phone`, `create_lesson_series` (0022),
    `create_lesson_series_preview`, `lesson_slot_conflicts`,
    `cancel_lesson`, `cancel_series_from`, `reschedule_lesson`,
    `substitute_teacher`, `teacher_vacation`, `teacher_vacation_preview`,
    `mark_attendance` (**0010**, не 0009 — в 0010 `coalesce` против
    NULL-роли), `mark_lesson_status`, `sell_subscription`,
    `sell_subscription_paid`, `freeze_subscription`,
    `unfreeze_subscription`, `transfer_remaining`; с `can_payments()`:
    `record_payment`, `refund_subscription`, `create_installment_plan`,
    `pay_installment`, `cancel_installment_plan`,
    `installment_plans_cancel_live` (role_in по центру подписки),
    `subscription_summary`, `subscription_visible_to_caller`,
    `payer_display_name` (ветка owner/admin). Тело — по `grep -n "create or
    replace function public.<имя>("` на момент написания, не по памяти;
    одна строка меняется. pgTAP: registrar lives / чужой центр / NULL-роль
    (кейс 0010) на перевыпущенных; finance 42501 на функциях стойки.
  - `0026_roles_finance_rpc.sql` — `can_finance()`: `record_expense`,
    `archive/restore_expense_category`, `archive/restore_payment_source`,
    `close_month` (`reopen_month` — только owner), `calc_salary` (ветка
    owner/admin + проверка специалиста), `approve_salary`,
    `record_salary_adjustment`, `salary_summary` (верхний список **и**
    фильтр в CTE `scope`). Не получает: `archive/restore_teacher`,
    `user_email`, функции расписания и учеников. `student_subscription_badge`
    — без правки, finance проходит насквозь (остаток занятий ребёнка —
    «ФИО и баланс», сознательно).
  - `0027_roles_policies.sql`: процедура `apply_role_rls(tbl, p_role,
    p_write boolean, p_soft_delete boolean)` — **без дефолтов** (12 таблиц
    каталога без `deleted_at`), политики `tenant_<role>_select` и, при
    записи, `tenant_<role>_insert`/`_update`; **`for all` не выдаётся никогда**
    — DELETE нельзя открыть опечаткой. Вызовы:
    - registrar, select+insert+update: `students`, `payers`, `groups`,
      `group_students`, `lessons`, `attendance`; select: `teachers`,
      `rooms`, `services`, `subscription_types`, `subscriptions` (правка
      `notes`/`allow_negative`/`deleted_at` — решение о деньгах, остаётся
      owner/admin), `subscription_freezes`, `payments`, `installment_plans`,
      `installments`, `student_payers` (append-only, кладёт триггер),
      `lesson_participants` (иначе состав группы на экране пуст —
      `lesson_participants_read` перечисляет роли), `financial_periods`.
      Нет: `expenses`, `expense_categories`, `teacher_rates`,
      `salary_adjustments`, `salary_runs`, `invitations`, `audit_log`,
      `events`.
    - finance, select+insert: `teacher_rates` (ставка — прямая запись под
      `approved_salary_guard`/`financial_period_guard`, как у admin; RPC
      нет); select: `payments`, `expenses`, `expense_categories` (+
      `_read_archived` — там `owner/admin` литералом), `payment_sources`,
      `financial_periods`, `salary_adjustments`, `salary_runs`, `teachers`,
      `payers`, `student_payers`, `students`, `subscriptions`,
      `subscription_freezes`, `subscription_types`, `installment_plans`,
      `installments`, `attendance`, `lessons`. Всё пишется через RPC.
      **Отступление от ТЗ, на решение владельца:** `lessons.notes`,
      `attendance.comment`, `students.notes` finance читает прямым запросом
      — витрины выручки `security_invoker` с `join lessons` (без политики —
      «выручка 0», а не «нет доступа»), `student_balance` — поверх
      `students`. Колоночного разделения для роли не бывает (ADR-005);
      честный путь — вынести заметки в отдельные таблицы (этап 7 заводит
      `lesson_notes`) — тогда политика finance к ним не применяется и
      колонка исчезает физически. Фиксируется явным pgTAP со ссылкой сюда.
      Нет: `groups`, `group_students`, `rooms`, `services`, `invitations`,
      `audit_log`, `events`, `lesson_participants`.
    - Вью с ролью в теле: `revenue_by_month/teacher/service`,
      `cash_by_source` — `can_finance()`; `student_balance` —
      `can_payments()`; `expense_categories_read_archived` — `can_finance()`.
    - Лестница: `change_member_role` — owner любую; admin — `teacher`,
      `registrar`, `finance`, не трогает owner/admin. `create_invitation`:
      `p_role in ('admin','teacher','parent','registrar','finance')`, admin
      не приглашает admin; `teacher_id` только у `teacher`.
    - `FEATURE_MATRIX.md`: курсив снимается, строки этапов 3–5 по коду; две
      клетки поправить: «Участники» — своя строка видна (как teacher/
      parent), «Плательщики У» у registrar — `archive_payer` не существует.
    - pgTAP: `set_eq` по `pg_policies` на каждую таблицу каталога (новая
      таблица этапа 7 без решения роняет тест); перебором по каталогу —
      своя/чужая/запретная для обеих ролей, после блока «чужой центр» явный
      `tests_claims`; лестница (admin→owner/admin — 42501, admin→registrar/
      finance — lives, приглашения); `cancel_installment_plan` и
      `refund_subscription` от обеих ролей — lives (цепочка
      `installment_plans_cancel_live`); `revenue_by_month` для finance
      непуст и **равен** сумме владельца; `student_balance` для обеих —
      `state = 'active'` на живом абонементе; `lesson_participants`:
      registrar 3 строки, finance 0, прямой insert — отказ у обоих.
  - В приложении (`layout.tsx:52` знает `owner|admin`) — зеркало «роль →
    экран» в Vitest на тех же случаях, что pgTAP; подсказка совпадает с
    отказом базы.
- pgTAP-пробелы из «Доработки» п.2 (каждый — отдельным кейсом, где нужно —
  правкой функции следующей миграцией):
  - переутверждение зарплаты после `reopen_month` — сейчас `approve_salary`
    после reopen даёт 23505 (`salary_runs_teacher_month_key`): нужно
    решение — `reopen_month` гасит снимки месяца (`salary_runs.cancelled_at`?)
    или второй approve заменяет снимок; замок месяца не должен быть
    ловушкой;
  - возврат при отмене: `refund_subscription` не создаёт `payments`
    (kind 'refund') — только списывает занятия и ставит cancelled; кейс
    «повторный возврат — исключение» и строка платежа — правка функции;
  - переплата: `record_payment` сейчас складывает молча (`overpaid` в
    `subscription_payment_summary`) — решение «отдельное действие, не
    молчаливое сложение»: отказ 22023 при `paid + amount > price` для
    kind 'payment' с привязкой к абонементу, переплата — только
    `correction` с явным комментарием;
  - `close_month` при planned-уроках: исключение с их ЧИСЛОМ в тексте —
    проверить формулировку 0014.
- `record_payment` с датой (`p_paid_on date`) вместо момента из браузера —
  перед `/app/finance` (замечание ревью 0018 №9).

**UI (промт, блок UI), по порядку:**

1. «Продать абонемент» → форма оплаты: сумма (по умолчанию полная),
   источник, дата; чекбокс «Рассрочка» → n платежей, первая дата,
   предпросмотр сумм из `core/finance.ts::splitInstallments` /
   `installmentDueDates`, создание — `sell_subscription_paid`.
   Роут `/app/students/[id]` (`subscriptions-panel.tsx`, `subscription-actions.ts`).
2. `/app/finance`: «Платежи» (таблица, фильтры, платёж/возврат),
   «Расходы», «Рассрочки» (`installments_view`, просроченные красным,
   WhatsApp), «Периоды» (`close_month` с предпросмотром незакрытых уроков).
3. `/app/salary`: месяц → `salary_summary` → раскрытие `calc_salary` →
   бонус/штраф → «Утвердить». Печать/PDF — если успеваю, иначе в отчёт.
4. `/app/settings/teacher-rates`.
5. Дашборд admin: `revenue_by_month`, `cash_by_source`, `student_balance`
   (долги), `installments_view` (просрочки). «План» не строится.
6. Teacher: `/app/my-salary` (`salary_summary` + `calc_salary` своих строк).
7. Parent: `/app/my` → «Платежи» (`payments` по RLS).

Каждый экран: zod-схемы форм в `packages/contracts`, строки — в
`apps/web/messages/ru.json`, ошибки — только через `errors.ts`, loading/
empty states, мобильный вид на preview.

### 2. Риски

- **Роли registrar/finance** — единственная правка, которая трогает RLS
  всех таблиц разом; ошибка в `apply_tenant_rls` открывает или закрывает
  всё. Понимаю хуже всего порядок: расширять процедуру и переприменять ко
  всем таблицам или писать политики поимённо. Решается отдельным Plan +
  два раунда `architect`.
- **Переутверждение после reopen_month** — снимок `salary_runs`
  неизменяем по замыслу (0017 Р2); любое «переутверждение» — это второй
  снимок или гашение первого, и оба меняют смысл `salary_summary`.
- **Форма продажи с рассрочкой** — предпросмотр сумм/дат в браузере против
  сервера: держит `p_expected_remaining_tiyin` в `create_installment_plan`
  и строки плана в ответе RPC, а не расчёт на клиенте.
- **Дата платежа**: сейчас `record_payment` принимает момент из браузера —
  платёж 1-го числа может попасть в предыдущий месяц по поясу центра и
  упереться в замок. В форме продажи закрыто (`p_paid_on date`), в
  `/app/finance` — правкой `record_payment` до экрана.

### 3. Что может задеть

- `sell_subscription`, `record_payment`, `create_installment_plan` — не
  меняются, обёртка зовёт их; e2e `attendance-subscriptions.spec.ts`
  (`actAndAwait('Продать абонемент', 'Абонемент продан')`) — уведомление
  сохраняется, форма получает новые поля с дефолтами (сумма = полная).
- `apply_tenant_rls` — при добавлении ролей переприменяется ко всем
  таблицам; `rls_smoke.test.sql` и все `*_read_own` политики — прогон
  целиком.
- **teacher**: не должен увидеть ни одной суммы — `payments`, `expenses`,
  `salary_runs`, `teacher_rates` чужие, `revenue_*`/`cash_*`: pgTAP 0013,
  0016, 0017, 0021 уже держат; новые экраны не должны подгружать эти
  таблицы под teacher (только `salary_summary`/`calc_salary` своих строк).
  **parent**: свои `payments`, `installments`, статус оплаты своего
  абонемента — и ничего агрегированного по центру (0018, 0021).
  **registrar/finance** — новые: registrar без зарплат и расходов, finance
  без клиники и заметок; матрица прав — источник, pgTAP на каждую таблицу.
- `subscription_payment_summary`, `installments_view`, витрины 0021 —
  читаются новыми экранами как есть; формы не считают деньги сами.

### 4. Критерии готовности

Чек-лист этапа (5 пунктов) кликом на staging плюс:

- чек-лист п.1 — pgTAP 0023 (продажа 4 000 / 2 000 / 2×1 000 одной
  транзакцией, атомарность при отказе плана и при замке месяца);
- п.2 — pgTAP 0017 (150000 → 200000, teacher видит своё, чужое 42501);
- п.3 — pgTAP 0013/0014/0016 (замок; correction текущим числом);
- п.4 — после правки `refund_subscription`: строка `payments` kind refund,
  повторный возврат — исключение;
- п.5 — pgTAP 0018 (overdue вчера, событие один раз);
- «Доработка» п.2: переутверждение после reopen, переплата — решения
  зафиксированы кейсами;
- роли registrar/finance: pgTAP на каждую таблицу под каждой ролью и
  «чужой центр»;
- DoD целиком, по пунктам, в этом отчёте.

## Что это даёт

<!-- пишется по завершении этапа -->

## Отступления от ТЗ

Накопленные по ходу бэкенда (подробно — в шапках миграций, Р-пункты):

- 0017: зарплата идёт по замороженному `attendance.paid_teacher_id`, а не
  по живому `effective_teacher_id`; `per_hour` платит одной строкой
  занятия; `salary_runs` без прямого чтения специалистом — итог через
  `salary_summary`; `approve_salary` только за прошедший месяц, `reopen`
  сознательно не строился (пересматривается «Доработкой» п.2).
- 0018–0020: строка рассрочки не хранит «оплачено» — выводится из
  `paid_tiyin` через `base_paid_tiyin` плана; `installments` вне
  `financial_period_guard` (денежный факт — платёж); планировщик
  `installments_notify` — этап 6, функция готова; архив ученика план не
  гасит, только уведомления.
- 0021: выручка (начисление по `deducted` + `done`) и зарплата
  (`pays_teacher`) — разные множества; безлимит в выручку не входит
  (колонка `unlimited_visits`); «план выручки» не строится.
- 0022 (параллельная сессия): составные FK `(id, center_id)` по всей
  схеме, не только `groups.teacher_id`.

## Проверки

| Что | Результат |
|---|---|
| pgTAP | 0013 (38), 0014, 0016 (36), 0017 (65), 0018 (83), 0021 (70), 0022 — все зелёные в CI |
| Unit | core: salary.test (32), finance.test (24) — 144/144 |
| CI | app / db / Playwright — зелёные на каждом PR; `main` был красным дважды (см. дефекты) |
| Чек-лист кликом | — (UI не начат) |
| Advisors | после 0017, 0018–0020 и 0022: без ошибок; только известные классы (definer-RPC для authenticated, составные FK без индекса — после 0022 их 51, INFO; две permissive-политики). Одно WARN `auth_rls_initplan` на `memberships_select_self_or_admin` (политика 0002, `auth.uid()` без `(select …)`) — не от этапа, правится следующей миграцией |

## Найденные дефекты

- 0014 (find в 0013): `generate_series(date,date,interval)` даёт
  `timestamptz` — не поймал typecheck, поймал pgTAP.
- 0017, три раунда ревью: `per_hour` ×N детей на группе; `per_lesson`
  обнулял оплату за состоявшееся групповое занятие («болел» на первом
  `student_id`); утечка цены абонемента специалисту через
  `salary_runs.lines`; двойная оплата при замене посреди отметок; пустой
  состав группы в фикстуре (`joined_at` по умолчанию — сегодня).
- 0018, три раунда: аванс до плана закрывал первую строку (→
  `base_paid_tiyin`); отмена гасила только неоплаченные строки — оплаченные
  «воскресали» после возврата (→ `installment_plans`, отмена целиком);
  взаимоблокировка `pay_installment` ↔ отмена абонемента (порядок захвата);
  `service_role` проходил обратную проверку `auth.uid() is null`; архив
  ученика — `status`, не `deleted_at` (0019).
- #38 влит на красном db-джобе до фикса — правило «PR только с готовым
  кодом» записано в память; #44 — устаревшая ветка правила уже применённую
  0018 (возвращена в #45).
- Коллизия номеров: #42 и #43 влились за минуту с одним номером 0021 —
  `schema_migrations_pkey`, `main` красный, переномерование в 0022 (#45).
  Правило «номер — по факту каталога и открытых PR» теперь в шапке
  `stages.md`.
- 0021: `sum(bigint)` даёт `numeric` — `is(numeric, bigint)` не
  резолвится; `reset role` не сбрасывает claims (четвёртый раз за проект).

## Что осталось владельцу

- pg_cron для `installments_notify` — этап 6 (тумблер расширения в
  дашборде).
- Leaked password protection (Advisors WARN) — тумблер Auth.
- Решения по «Доработке» п.2 (переутверждение после reopen, переплата) —
  предложу в Plan миграции, но это продуктовые решения.
