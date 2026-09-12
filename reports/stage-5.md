# Этап 5 — Финансы и зарплата

Дата: 2026-09-12 (в работе)
PR: #32 (0013–0014), #35 (0016), #37 (0017), #38/#40/#44 (0018–0020), #43 (0021), #42/#45 (0022), #46 (0023), #48 (0024), #49 (0025, параллельная сессия), #51 (0026), #52 (0027), #53 (0028)
Миграции: 0013_finance_core, 0014_finance_core_fixes, 0016_expenses, 0017_teacher_rates_and_salary, 0018_installments, 0019_installments_notify_archived, 0020_installment_plans, 0021_revenue_views, 0022_center_scoped_fks, 0023_sell_subscription_paid, 0024_access_hygiene, 0025_mark_lesson_status_role_guard, 0026_roles_registrar_rpc, 0027_roles_finance_rpc, 0028_roles_policies

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
  - `invitations`: табличный `insert` давал администратору `POST` с
    `role = 'admin'` в обход лестницы `create_invitation`, табличный
    `update` — правку роли/токена/`accepted_at` у выданной ссылки. Теперь
    `select` + `update (expires_at)` (единственный прямой писатель —
    `cancelInvitation`).
  - **Последний владелец — триггер, не две функции.** `change_member_role` и
    `revoke_membership` считают владельцев в plpgsql, а `accept_invitation`
    делала `on conflict do update set role` мимо обеих: единственный
    владелец, кликнувший приглашение с ролью `parent` (после 0027 —
    правдоподобное `finance`), оставлял центр без владельца. Триггер
    `memberships_last_owner_guard` (`before delete or update of role,
    center_id`, 23514 «В центре должен остаться хотя бы один владелец»;
    RPC отказывают раньше своими текстами «понизить»/«отключить») с
    advisory-замком по центру — две транзакции не понизят двух владельцев
    одновременно. **Следствие, решение:** удалить единственного владельца
    (каскад из `auth.users`) или его центр нельзя даже `service_role` —
    сначала назначается второй владелец. `accept_invitation`: та же роль —
    только связывание с карточкой (`teacher_id`/`payer_id`; иначе
    специалисту без карточки её не выдать — `change_member_role` умеет
    лишь занулять), другая роль — отказ 23505 с рабочим путём «отключить и
    пригласить заново».
  - Не закрыто этой миграцией, в план: `tenant_admin` по-прежнему `for
    all` — DELETE держится на отсутствии гранта (забор 0024 ловит новую
    таблицу на CI, но не в схеме), а `service_role` минует и RLS, и грант.
    Следующий шаг — `apply_tenant_rls` без `for all` (select/insert/update)
    и `before delete`-триггер на таблицах с `deleted_at` (0028, после
    ролей).
  - pgTAP: забор по каталогу без белых списков — `authenticated` без
    `DELETE` ни на одной таблице/вью `public`, anon без единого права и
    колоночного гранта; `invitations` без insert/табличного update;
    тест 0021 — белый список пустеет, вью вне списка 10; последний
    владелец на прямом update/delete/переносе центра, замок в теле
    триггера, штатное понижение через `change_member_role`, удаление
    одного из двух; `accept_invitation` — участнику с другой ролью отказ,
    той же — связывание, новичку — членство.
- Роли `registrar` и `finance` («Доработка» п.1) — три миграции, три PR,
  **порядок инвертирован**: сначала RPC, последней — политики и лестница.
  Пока `memberships_role_check` не расширен, строка с новой ролью не
  существует, промежуточные состояния безопасны по построению.
  **Решение: `tenant_admin` не расширяется** — остаётся owner/admin; для
  новых ролей отдельные политики по явному списку таблиц; таблица без
  решения закрыта — этап 7 (диагностика, цели, ДЗ, `lesson_notes`) не
  достанется бухгалтеру по умолчанию.
  - `0026_roles_registrar_rpc.sql` (номер 0025 занял #49 параллельной
    сессии — тот же фикс NULL-роли в `mark_lesson_status`; тело берётся
    оттуда): `memberships_role_check` и `invitations_role_check` +=
    `registrar`, `finance` (лестница ещё не пускает — назначить нельзя,
    тесты сеют членство напрямую). Три предиката вместо литералов в каждом
    гейте — иначе обёртка и внутренняя функция разъедутся молча
    (`installment_plans_cancel_live` уже заблокировала бы обе роли):
    `can_front_desk(p_center uuid default current_center())` =
    owner/admin/registrar, `can_finance(...)` = owner/admin/finance,
    `can_payments(...)` = все четыре; `stable`, invoker,
    `coalesce(role_in(p_center), '')`. Перевыпуск с `can_front_desk()`:
    `create_student_with_payer`, `archive_student`, `restore_student`,
    `find_payer_by_phone`, `create_lesson_series` (0022),
    `create_lesson_series_preview`, `lesson_slot_conflicts`,
    `cancel_lesson`, `cancel_series_from`, `reschedule_lesson`,
    `substitute_teacher`, `teacher_vacation`, `teacher_vacation_preview`,
    `mark_attendance` (**0010**, не 0009 — в 0010 `coalesce` против
    NULL-роли), `mark_lesson_status` (0025), `sell_subscription`,
    `sell_subscription_paid`, `freeze_subscription`,
    `unfreeze_subscription`, `transfer_remaining`, **`refund_subscription`**
    (ревью кода: это списание остатка и отмена абонемента, а не платёж —
    роль, которой нельзя продать и заморозить, не гасит; бухгалтер проводит
    возврат денег через `record_payment(kind = 'refund')`); с
    `can_payments()`: `record_payment`, `create_installment_plan`,
    `pay_installment`, `cancel_installment_plan`,
    `installment_plans_cancel_live` (role_in по центру подписки),
    `subscription_summary`, `subscription_visible_to_caller`,
    `payer_display_name` (ветка owner/admin). Тело — по `grep -nE "create
    (or replace )?function public\.<имя>\("` по всем миграциям, не по
    памяти; одна строка меняется. **Решение (ревью кода):** инвокерные
    калькуляторы (`refund_calc`, `subscription_lessons_left`, вью
    `student_balance`/`installments_view`) для новых ролей до 0028 отдают
    NULL/пусто — прикладной путь к остатку и сумме возврата только
    `subscription_summary` (definer, `can_payments`). pgTAP: registrar
    lives по всему сценарию стойки (id, которые RPC не возвращает, — от
    postgres; проверки состояния после `reset role`), finance/teacher/
    чужой центр/NULL-роль — отказы, `refund_subscription` от finance 42501.
  - `0027_roles_finance_rpc.sql` — заодно долг 0011, который 0026
    перевыпустила как есть: `cancel_series_from` и `teacher_vacation`
    приводят `p_from::timestamptz` в поясе сессии, не центра — занятие в
    Бишкеке раньше 06:00 в граничный день в отмену не попадает (в CI не
    видно: UTC). Чинится через `center_timezone`, как в `sell_subscription_paid`.
    `can_finance()`: `record_expense`,
    `archive/restore_expense_category`, `archive/restore_payment_source`,
    `close_month` (`reopen_month` — только owner), `calc_salary` (ветка
    owner/admin + проверка специалиста), `approve_salary`,
    `record_salary_adjustment`, `salary_summary` (верхний список **и**
    фильтр в CTE `scope`). Не получает: `archive/restore_teacher`,
    `user_email`, функции расписания и учеников. `student_subscription_badge`
    — без правки, finance проходит насквозь (остаток занятий ребёнка —
    «ФИО и баланс», сознательно).
  - `0028_roles_policies.sql`: процедура `apply_role_rls(tbl, p_role,
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
    - finance (список «запись без чтения» из шапки 0027, Р8 — каждая
      строка отдельным `create policy` и pgTAP-кейсом `is(count, N)`, не
      `lives_ok`: отсутствующая политика даёт ноль строк, не ошибку):
      select+insert: `teacher_rates` (ставка — прямая запись под
      `approved_salary_guard`/`financial_period_guard`, как у admin; RPC
      нет); select+insert+update: `expense_categories` (+ `_read_archived`
      — там `owner/admin` литералом → `can_finance()`), `payment_sources`
      (создание статьи/источника — прямой insert, RPC только
      archive/restore); select: `payments`, `expenses` (update (comment) —
      грант уже колоночный), `financial_periods` (иначе «месяц открыт» на
      закрытом), `salary_adjustments`, `salary_runs` (`_read_own` у
      бухгалтера пуст), `teachers`, `payers`, `student_payers`, `students`,
      `subscriptions`, `subscription_freezes`, `subscription_types`,
      `installment_plans`, `installments`, `attendance`, `lessons`.
      Остальное пишется через RPC. Зеркально — registrar на этих же
      таблицах: ноль строк и 42501 на запись.
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
- «Доработка» п.2 и дата платежа — после ревью плана (`architect`, 15
  находок) делится на две миграции: (а) без продуктовых решений, (б) —
  после решений владельца (см. «Что осталось владельцу»).
  - **`0029_salary_runs_and_payment_date.sql` (а):**
    - Отмена снимка зарплаты — **отдельное явное действие**
      `cancel_salary_run(p_teacher_id, p_month)` (owner), а не побочный
      эффект `reopen_month`: «утверждено» и «закрыто» — независимые факты
      (0017), молчаливая отмена снимков восьми специалистов из-за правки
      одного платежа — не то, что хочет владелец. `salary_runs.cancelled_at`;
      unique → частичный `salary_runs_teacher_month_live_key where
      cancelled_at is null`; триггер неизменяемости `salary_runs_immutable`
      (before update or delete): единственный разрешённый переход —
      `cancelled_at null → now()`, всё остальное и delete — отказ (снимок
      держится на триггере, не на отсутствии гранта); `approved_salary_guard`
      — `cancelled_at is null` в **обеих** ветках (new и old month);
      `salary_summary` — живой снимок в `approved_run_id`, отменённые видны
      колонкой `cancelled_runs integer`; событие `salary.run_cancelled`
      (одно на снимок) — zod в `events.ts` + pgTAP на точную строку `type`.
      Повторный `approve_salary` без отмены — 23505 по новому имени, текст
      в `errors.ts`. Тела `approve_salary`/`salary_summary` — из **0027**,
      не 0017 (гейт `can_finance`).
    - **Дата платежа.** Старая 8-параметровая `record_payment` дропается,
      новая с `p_paid_on date default null` (тело — из **0026**, гейт
      `can_payments`); `p_paid_on` → полночь по поясу центра; будущее —
      22023; переданы и `p_paid_at`, и `p_paid_on` — 22023 (не приоритет);
      нижняя граница — не старше года от сегодня по центру (опечатка
      годом не уезжает в 2024; граница по `created_at` плательщика
      отбивала бы законный платёж задним числом за плательщика, созданного
      сегодня). `sell_subscription_paid` переводится на `p_paid_on` — одна
      конвертация вместо двух. Внутренние позиционные вызовы (8
      аргументов, `pay_installment`) резолвятся в новую. После `drop` —
      гранты заново; 0007 — новая сигнатура вместо старой; тест 0013 —
      строка с грантом на старую сигнатуру правится. Снимок зарплаты не
      удаляется никаким путём, включая каскад от `centers` (как 0024);
      `cancelled_by` — без FK на `auth.users` (иначе `on delete set null`
      упирался бы в триггер). Параметр въезжает
      мёртвым: в `apps/web` вызовов `record_payment` пока нет (экран
      `/app/finance` не написан) — это записано, а не «выполнено».
    - `close_month` при двух незакрытых занятиях — pgTAP `throws_like
      '%— 2,%'` (текст — 0027:231, совпадает с 0014).
  - **`0030_refund_and_overpay.sql` (б), после решений владельца, одной
    веткой с формой возврата (server action и тесты 0010/0026 правятся в
    том же PR):**
    - Возврат — платёжная строка kind 'refund' на `least(refund_calc,
      paid_tiyin)`: `refund_calc` — стоимость неотработанных занятий, а не
      полученные деньги; отрицательный платёж на `refund_calc` по частично
      оплаченному абонементу упал бы в `subscriptions_paid_not_negative`
      (23514 без текста) и сделал бы возврат недоступным для главного
      сценария этапа (продажа 4 000 / оплата 2 000). Что показывает диалог
      и что значит `p_expected_tiyin` — решение владельца. `p_source_id`
      обязателен при сумме > 0 — только вместе с формой, где его можно
      выбрать. Повторный возврат — не `if`, а частичный unique на
      `payments (subscription_id) where kind = 'refund'`. Новое
      `payment_state = 'refunded'` в `subscription_payment_summary` и
      зеркало в `core/finance.ts::paymentState` (иначе родитель видит
      `unpaid` на 4 000 после возврата).
    - Переплата — только если владелец решает «оплатить наперёд нельзя»:
      тогда триггер на `payments` для kind 'payment' **и** положительной
      'correction' с `subscription_id` (иначе текст ошибки показывает
      обход), замок и чтение одной инструкцией `select … for update`,
      порядок захвата subscriptions → payments (как `pay_installment`)
      записывается в `Database.md`; тест 0018 (`overpaid`) переписывается,
      Р8 из 0023 отменяется явным абзацем. Если решает «можно» — триггера
      нет, только предупреждение в форме. Платёж без `subscription_id` на
      сумму больше цены — фиксируется текущим поведением явно.

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
| pgTAP | 0013 (38), 0014, 0016 (36), 0017 (65), 0018 (83), 0021 (70), 0022, 0023 (47), 0024 (33), 0026 (69), 0027 (53) — зелёные в CI; 0028 (74) — на ревью |
| Unit | core: salary.test (32), finance.test (24) — 144/144 |
| CI | app / db / Playwright — зелёные на каждом PR; `main` был красным дважды (см. дефекты) |
| Чек-лист кликом | — (UI не начат) |
| Advisors | после 0024–0025: WARN `auth_rls_initplan` на `memberships` ушёл, остальное без изменений. После 0017, 0018–0020, 0022 и 0023: без ошибок; только известные классы (definer-RPC для authenticated, составные FK без индекса — после 0022 их 51, INFO; две permissive-политики). Одно WARN `auth_rls_initplan` на `memberships_select_self_or_admin` (политика 0002, `auth.uid()` без `(select …)`) — не от этапа, правится следующей миграцией |

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
- 0024 (ревью плана ролей): DELETE у `authenticated` на 12 таблицах
  0001–0006 держался на одной `tenant_admin for all`; `accept_invitation`
  перезаписывала роль по ссылке мимо проверки последнего владельца;
  табличный `insert` на `invitations` обходил лестницу `create_invitation`.
- 0026 (при перевыпуске гейтов): `mark_lesson_status` (0006) пропускала
  NULL-роль — `elsif v_role not in ('owner','admin')` при NULL не
  срабатывает, а событие пишется только при `cancelled`; пользователь с
  отозванным членством и старым JWT мог закрывать занятия. 0010/0011 её не
  тронули. Нашли две сессии независимо: #49 закрыл `coalesce` (0025), 0026
  перевыпускает с предикатом. Второй дубль номера за этап (после 0021) —
  проверка «каталог + открытые PR» не ловит PR, открытый и влитый между
  двумя моими проверками.
- 0026 (ревью кода): `not (false or NULL)` в `mark_attendance` — NULL, та
  же дыра в новой форме; тест читал `lessons`/`installments` под registrar
  без политик и получал NULL в подзапросах; `refund_calc` — invoker, для
  новых ролей NULL; `refund_subscription` с `can_payments` отдавала
  бухгалтеру отмену абонемента.

## Что осталось владельцу

- pg_cron для `installments_notify` — этап 6 (тумблер расширения в
  дашборде).
- Leaked password protection (Advisors WARN) — тумблер Auth.
- Решения по «Доработке» п.2 — три, все продуктовые (план 0030 ждёт их):
  1. **Возврат:** сумма возврата денег = `least(стоимость неотработанных
     занятий, внесено)`; что показывает диалог — обе цифры или одну?
     Возврат без источника оплаты запрещён (как продажа)?
  2. **Переплата:** «оплатить наперёд» запрещено (триггер, включая
     положительные корректировки с привязкой к абонементу) или разрешено
     (только предупреждение в форме, `overpaid` остаётся)?
  3. **Снимок зарплаты после `reopen_month`:** отмена снимка — отдельное
     действие владельца (`cancel_salary_run`), `reopen` его не трогает —
     так реализуется в 0029 по умолчанию; если нужно наоборот (reopen
     отказывает, пока есть утверждённые снимки) — сказать до 0029.
- Отступление Р5 (0028): finance читает `students.notes`, `lessons.notes`,
  `attendance.comment` — оставить до выноса заметок в отдельные таблицы на
  этапе 7 или закрыть сейчас (тогда витрины выручки и `student_balance` для
  finance переписываются на definer-функции)?
- Удалить единственного владельца или его центр нельзя даже `service_role`
  (0024) — сначала назначается второй владелец; при удалении пользователя
  из дашборда Supabase это будет отказ.
