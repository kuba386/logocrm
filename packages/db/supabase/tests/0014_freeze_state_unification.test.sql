-- pgTAP: 0014_freeze_state_unification — единый источник правды о заморозке.
-- Даты — всегда через public.center_today(center_id)/center_timezone(center_id),
-- никогда голый current_date/now()::date: расхождение часового пояса сессии
-- (обычно UTC) и центра (Asia/Bishkek, UTC+6) уже один раз уронило CI на main
-- (fix(tests): 0010 — заморозка "сегодня" смешивала два разных часовых пояса).
--
-- Один студент = один сценарий, без общих абонементов между тестами: выбор
-- кандидата (badge/attendance/student_balance) сортирует "незамороженные
-- первыми" и молча меняет ответ, если на одном студенте случайно оказались
-- два абонемента от разных, не связанных друг с другом тестов.
--
-- Занятия, которые реально отмечаются (insert into attendance), никогда не
-- датируются РОВНО center_today() — attendance_fill_and_check отказывает
-- "занятие ещё не началось" при starts_at > now(), а конкретный час CI не
-- контролирует: "сегодня в 10:00" может оказаться будущим, если раннер
-- стартовал в 3 часа ночи по Бишкеку. Там, где нужна дата ВНУТРИ окна
-- заморозки, а не именно "сегодня", берётся center_today() - 1 — заведомо
-- прошлый час суток на любой момент "сегодня", и заморозка при этом
-- начинается с той же даты, а не с center_today().

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(54);

-- Фикстуры: центры, роли, справочники ------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','owner-b@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','teacher@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0001-0000-0000-000000000001','Центр А','freeze-a','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0001-0000-0000-000000000002','Центр Б','freeze-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','Препод А');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','Иванова А.','+996700111001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin) values
  ('99999999-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','Индивидуальное',45,50000);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001','owner',null,null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0001-0000-0000-000000000002','owner',null,null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001','teacher','aaaaaaaa-0001-0000-0000-000000000001',null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0001-0000-0000-000000000001','parent',null,'bbbbbbbb-0001-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- Тип "8 занятий" (kind=lessons, без срока) — общий, ссылки на него не мешают
-- друг другу: type_id используется только для service_id-фильтра в подборе.
insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('77777777-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','Восемь занятий','99999999-0001-0000-0000-000000000001','lessons',8,400000);
insert into public.subscription_types (id, center_id, name, service_id, kind, period_days, price_tiyin) values
  ('77777777-0001-0000-0000-000000000002','cccccccc-0001-0000-0000-000000000001','Месяц','99999999-0001-0000-0000-000000000001','period',30,600000);

-- Студенты: один на сценарий, primary_teacher_id = препод А везде (нужен для
-- teacher_teaches_student), payer_id = плательщик А везде (нужен для
-- parent_of_student). Обе связи не пересекаются с содержанием тестов.
insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','С1 Данияр','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000002','cccccccc-0001-0000-0000-000000000001','С2 Азиз','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000003','cccccccc-0001-0000-0000-000000000001','С3 Бекзат','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000004','cccccccc-0001-0000-0000-000000000001','С4 Гульнара','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000005','cccccccc-0001-0000-0000-000000000001','С5 Дамир','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000006','cccccccc-0001-0000-0000-000000000001','С6 Эльвира','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000007','cccccccc-0001-0000-0000-000000000001','С7 Жаннат','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000008','cccccccc-0001-0000-0000-000000000001','С8 Нурлан','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001'),
  ('eeeeeeee-0001-0000-0000-000000000009','cccccccc-0001-0000-0000-000000000001','С9 Айгерим','bbbbbbbb-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001');


-- 1-3. Главный баг: датированная заморозка не держит статус навсегда --------------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000001','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20, null);

-- Занятия студента 1 нужны здесь, ДО тестов видимости (4-8): teacher_
-- teaches_student смотрит не на primary_teacher_id, а на реальное участие
-- в занятии через lesson_participants (0006_schedule.sql:395-402) — без
-- хотя бы одного занятия бейдж специалиста (тест 6) откажет "этот ребёнок
-- не на ваших занятиях" ещё до проверки заморозки.
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000001',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '08:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '08:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001')),
  ('44444444-0001-0000-0000-000000000002','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000001',
    -- today-10, не today-40: абонемент 1 начинается today-20
    -- (s.starts_at <= v_lesson_date) — более ранняя дата исключила бы
    -- его из кандидатов, отметка ушла бы в долг вместо списания.
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 10) + time '09:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 10) + time '09:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;

-- 1. Заморозка целиком в прошлом — уже истекла по календарю.
select public.freeze_subscription('88888888-0001-0000-0000-000000000001'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 15,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 8);
select is(public.subscription_state('88888888-0001-0000-0000-000000000001'), 'active',
  'Заморозка, истёкшая по календарю, не держит subscription_state=frozen навсегда — главный баг миграции');

-- 2. Вторая заморозка, покрывающая сегодня.
select public.freeze_subscription('88888888-0001-0000-0000-000000000001'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 2,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 5);
select is(public.subscription_state('88888888-0001-0000-0000-000000000001'), 'frozen',
  'Заморозка, покрывающая сегодня: subscription_state = frozen');
reset role;

-- 3. Защёлка ловит то, что простая проверка "абонемент активен" пропустила
-- бы: обе заморозки — в будущем, не покрывают сегодня, subscription_state
-- между ними остаётся 'active' на каждой отдельной проверке. Отдельный
-- абонемент (не 1): на 1 уже вторая заморозка покрывает сегодня, значит
-- v_state='frozen' и третья попытка упала бы на более простой проверке
-- "можно заморозить только действующий", а не дошла бы до защёлки вовсе.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-00000000000c','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000008','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 5, null);
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select public.freeze_subscription('88888888-0001-0000-0000-00000000000c'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 30,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 37);
select is(public.subscription_state('88888888-0001-0000-0000-00000000000c'), 'active',
  'Будущая заморозка не покрывает сегодня — subscription_state = active, "простая" проверка её бы пропустила');
select throws_ok(
  $q$ select public.freeze_subscription('88888888-0001-0000-0000-00000000000c'::uuid,
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 50,
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 57) $q$,
  '22023', 'У абонемента уже есть незакрытая заморозка',
  'Вторая будущая заморозка отклонена ИМЕННО защёлкой — обе проверки "активен" её бы пропустили (раздел 6)');
reset role;
select is(
  (select status from public.subscriptions where id = '88888888-0001-0000-0000-000000000001'),
  'active', 'subscriptions.status остался active всё это время — frozen не значение колонки (раздел 2)');
select throws_ok(
  $q$ update public.subscriptions set status = 'frozen' where id = '88888888-0001-0000-0000-000000000001' $q$,
  '23514', null, 'Прямая попытка записать status=frozen отклонена констрейнтом');


-- 4-10. Видимость: родитель, специалист, чужой центр (используют абонемент 1) --------

-- 4. Родитель того же ребёнка видит frozen напрямую, а не RLS-обрезанный active.
select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select is(public.subscription_state('88888888-0001-0000-0000-000000000001'), 'frozen',
  'Родитель видит frozen напрямую (round3, находка 1)');
select cmp_ok(public.subscription_freeze_days('88888888-0001-0000-0000-000000000001'), '>', 0,
  'Родителю дни заморозки — реальное число, не 0 из-за спрятанной RLS-строки');
reset role;

-- 5. Владелец ЧУЖОГО центра не видит ни состояние, ни дни этого абонемента.
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0001-0000-0000-000000000002');
set local role authenticated;
select is(public.subscription_state('88888888-0001-0000-0000-000000000001'), null::text,
  'Чужой центр: subscription_state — NULL, не факт о чужой заморозке');
-- Грант на subscription_freeze_days есть у authenticated целиком (Postgres
-- не различает owner/admin/parent внутри одной роли) — видимость проверяет
-- сама функция через subscription_visible_to_caller и на чужом центре
-- отдаёт NULL тем же путём, что раньше давала RLS у invoker-версии.
select is(public.subscription_freeze_days('88888888-0001-0000-0000-000000000001'), null::integer,
  'Дни заморозки чужого абонемента — NULL, не отказ в правах: функция вызываема, видимость проверяет она сама');
reset role;

-- 6. Специалист: бейдж — словом; прямые RPC той же функцией — тоже NULL,
-- не больше. subscription_state_unchecked — исключение, у неё нет своей
-- проверки видимости вообще, поэтому она остаётся закрытой грантом.
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select is(public.student_subscription_badge('eeeeeeee-0001-0000-0000-000000000001'), 'заморожен',
  'Специалист видит слово «заморожен» через бейдж своего ученика');
select is(public.subscription_state('88888888-0001-0000-0000-000000000001'), null::text,
  'Специалист напрямую через subscription_state получает NULL, не категорию (round5, находка 3)');
select is(
  public.subscription_current_freeze('88888888-0001-0000-0000-000000000001', public.center_today('cccccccc-0001-0000-0000-000000000001')),
  null::daterange,
  'subscription_current_freeze специалисту напрямую — NULL, не точный диапазон (проверка видимости внутри функции)');
select throws_ok(
  $q$ select public.subscription_state_unchecked('88888888-0001-0000-0000-000000000001') $q$,
  '42501', null, 'subscription_state_unchecked закрыта от authenticated совсем, включая владельца своего центра');

-- 7. Специалист не видит витрину student_balance вовсе — фильтр роли на
-- вьюхе (round4, находка 1: регрессия против 0009_attendance.test.sql:228-231).
select is((select count(*)::int from public.student_balance), 0,
  'Специалист не видит student_balance вовсе — фильтр роли на вьюхе, не только на калькуляторах');
reset role;

-- 8. Прямая запись в subscription_freezes закрыта грантом полностью — не
-- блокер (0008:687-696 и так закрывал), но теперь единственный источник
-- правды, и это стоит держать проверяемым (round2, находка 13).
select ok(
  not has_table_privilege('authenticated', 'public.subscription_freezes', 'INSERT')
  and not has_table_privilege('authenticated', 'public.subscription_freezes', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.subscription_freezes', 'DELETE'),
  'authenticated не может писать в subscription_freezes напрямую — только через freeze/unfreeze_subscription');


-- 9-11. Отметка: единственный абонемент заморожен на дату занятия --------------------
-- (занятия 1 и 2 уже вставлены в самом начале файла, до тестов видимости)

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;

-- Прямой insert/update в attendance для teacher отклонён бы RLS
-- (tenant_admin — только owner/admin, 0004:24-47) ещё до триггера —
-- реальный путь записи всегда mark_attendance/mark_attendance_bulk,
-- security definer, коды статусов 'present'/'sick'/'late'/'absent' из
-- seed_attendance_statuses (0008:84-98). throws_ok сверяет errcode
-- отдельно от текста (третий параметр — точное совпадение сообщения
-- целиком, не подстрока — при динамической дате в тексте это неприменимо;
-- содержимое сообщения уже прочитано вручную в CI при отладке).

-- 9. Занятие ВЧЕРА — внутри окна заморозки [-2,+5) абонемента 1: новое
-- списание — исключение, а не тихий долг.
select throws_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000001','present') $q$,
  '22023', null, 'Занятие внутри окна заморозки: исключение, не тихий долг');
select is((select count(*)::int from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000001'), 0,
  'Строки в attendance не осталось — транзакция отменена целиком');

-- 10. Занятие 10 дней назад — вне окна заморозки [-2,+5): отметка проходит и
-- списывается как обычно (заморозка проверяется по дате ЗАНЯТИЯ, не по факту
-- существования какой-либо заморозки вообще).
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000002','eeeeeeee-0001-0000-0000-000000000001','present') $q$,
  'Занятие вне окна заморозки отмечается и списывается как обычно');
select is(
  (select subscription_id from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000002'),
  '88888888-0001-0000-0000-000000000001'::uuid, 'Списалось именно с абонемента 1');

-- 11 (тест 25-стиль из 0010). Смена статуса у ЭТОЙ уже привязанной отметки —
-- заморозка (по датам покрывающая сегодня, но не дату занятия) её не
-- касается. mark_attendance повторно на тот же lesson_id/student_id — это
-- and UPDATE изнутри (обработчик unique_violation, 0009:556-569), не новый insert.
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000002','eeeeeeee-0001-0000-0000-000000000001','sick') $q$,
  'Смена статуса у уже привязанной отметки не проверяет заморозку заново (продукт-решение 3)');
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000002','eeeeeeee-0001-0000-0000-000000000001','present') $q$,
  'Возврат к списывающему статусу той же отметки — тоже не падает');
select is(
  (select subscription_id from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000002'),
  '88888888-0001-0000-0000-000000000001'::uuid, 'Привязка к абонементу 1 пережила оба переключения статуса');
reset role;


-- 12. allow_negative не пробивает заморозку — это не про деньги -----------------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at, allow_negative) values
  ('88888888-0001-0000-0000-000000000002','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000002','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000002', null, 600000, 20000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 5, public.center_today('cccccccc-0001-0000-0000-000000000001') + 25, true);
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000003','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000002',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '10:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '10:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
-- Бессрочная (без p_to): нужна такой ниже, в тесте на subscription_summary
-- (freeze_to = NULL для "пока не разморозят"). С вчера, не с сегодня —
-- занятие теста 12 тоже вчерашнее (шапка файла, "занятие ещё не началось").
select public.freeze_subscription('88888888-0001-0000-0000-000000000002'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 1);
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select throws_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000003','eeeeeeee-0001-0000-0000-000000000002','present') $q$,
  '22023', null, 'allow_negative не спасает от заморозки — исключение всё равно срабатывает');
reset role;


-- 13. Заморожен и одновременно исчерпан (без allow_negative) — долг, не исключение --

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, lessons_used, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000003','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000003','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 90, null);
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000004','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000003',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '11:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '11:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

-- Абонемент уже exhausted (lessons_used=lessons_total) — freeze_subscription
-- отказал бы "можно заморозить только действующий"; заморозка тут и не нужна
-- для проверки: exhausted сам по себе исключает его из кандидатов ДО всякой
-- заморозки. Тест фиксирует именно это — а не то, что он ещё и заморожен.
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000004','eeeeeeee-0001-0000-0000-000000000003','present') $q$,
  'Исчерпанный (без allow_negative) абонемент — отметка проходит в долг, не исключение (раздел 11, известная асимметрия)');
select is(
  (select subscription_id from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000004'), null::uuid,
  'Привязки к исчерпанному абонементу нет — цена по услуге, событие no_subscription');
reset role;
-- reset role откатывает роль Postgres, но не request.jwt.claims (set_config
-- с is_local=true живёт до конца транзакции) — без нового tests_claims эта
-- проверка унаследовала бы claims специалиста с предыдущего блока, а у
-- специалиста subscription_visible_to_caller больше не пропускает вовсе
-- (раздел 4) — subscription_state тихо вернула бы NULL, а не exhausted.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select is(public.subscription_state('88888888-0001-0000-0000-000000000003'), 'exhausted',
  'Ярлык — exhausted, не frozen: порядок CASE ставит exhausted раньше (round3, находка 4)');
reset role;


-- 14. Два кандидата — один заморожен, другой активен: выбирается активный ------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000004','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000004','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 40, null);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000005','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000004','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 5, null);
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000005','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000004',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '12:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '12:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select public.freeze_subscription('88888888-0001-0000-0000-000000000004'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 1,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 10);
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000005','eeeeeeee-0001-0000-0000-000000000004','present') $q$,
  'Есть незамороженный кандидат — отметка проходит без исключения');
select is(
  (select subscription_id from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000005'),
  '88888888-0001-0000-0000-000000000005'::uuid, 'Списалось именно с НЕзамороженного абонемента 5, не с 4');
reset role;


-- 15-16. Групповая отметка: один заморожен — откат всей группы ----------------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000006','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000005','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20, null);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000007','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000006','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20, null);
-- lessons.lessons_check1: (group_id is null) <> (student_id is null) —
-- групповое занятие обязано ссылаться на настоящую группу, "ни то ни
-- другое" не проходит констрейнт. lesson_participants для группы
-- заполняет триггер (rebuild_lesson_participants, 0006:222-252) сам из
-- group_students — вручную вставлять её нельзя (защёлкнута отдельным
-- гейтом, 0007_lock_down_participant_functions.sql:44-47).
insert into public.groups (id, center_id, name, teacher_id) values
  ('dddddddd-0001-0000-0000-000000000001','cccccccc-0001-0000-0000-000000000001','Группа Т','aaaaaaaa-0001-0000-0000-000000000001');
-- joined_at — явно, не по умолчанию (current_date сессии, обычно UTC):
-- rebuild_lesson_participants берёт состав группы "вошёл не позже даты
-- занятия" (0006:249), а занятие теперь вчерашнее (шапка файла) — если
-- joined_at окажется today по UTC, а занятие today-1 по центру, дефолт
-- будет ПОЗЖЕ занятия, и участник в состав не попадёт вовсе.
insert into public.group_students (group_id, student_id, center_id, joined_at) values
  ('dddddddd-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000005','cccccccc-0001-0000-0000-000000000001', public.center_today('cccccccc-0001-0000-0000-000000000001') - 30),
  ('dddddddd-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000006','cccccccc-0001-0000-0000-000000000001', public.center_today('cccccccc-0001-0000-0000-000000000001') - 30);
insert into public.lessons (id, center_id, service_id, teacher_id, group_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000006','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','dddddddd-0001-0000-0000-000000000001',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '13:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) + time '13:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select public.freeze_subscription('88888888-0001-0000-0000-000000000006'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') - 1,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 10);
reset role;

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
-- mark_attendance_bulk сама зовёт mark_attendance по каждому элементу
-- (0010:561-566) — ключ 'status_code', не 'status_id' (текстовый код из
-- attendance_statuses.code, 0008:84-98), обрабатывает по возрастанию
-- student_id: eeeeeeee-...0005 (Дамир) раньше eeeeeeee-...0006 (Эльвира).
select throws_ok(
  $q$ select public.mark_attendance_bulk('44444444-0001-0000-0000-000000000006',
        jsonb_build_array(
          jsonb_build_object('student_id','eeeeeeee-0001-0000-0000-000000000005','status_code','present'),
          jsonb_build_object('student_id','eeeeeeee-0001-0000-0000-000000000006','status_code','present')
        )) $q$,
  '22023', null, 'Групповая отметка с одним замороженным ребёнком: 22023, откат целиком (продукт-решение 4)');
select is((select count(*)::int from public.attendance where lesson_id = '44444444-0001-0000-0000-000000000006'), 0,
  'Ни одна отметка группового занятия не сохранилась — откат целиком, включая незамороженную Эльвиру');
reset role;


-- 17-19. Guard: заморозка задним числом поверх уже списанного -----------------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000008','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000007','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20, null);
insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at) values
  ('44444444-0001-0000-0000-000000000007','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000007',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 3) + time '09:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001') - 3) + time '09:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001')),
  ('44444444-0001-0000-0000-000000000008','cccccccc-0001-0000-0000-000000000001','99999999-0001-0000-0000-000000000001','aaaaaaaa-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000007',
    ((public.center_today('cccccccc-0001-0000-0000-000000000001')) + time '09:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
    ((public.center_today('cccccccc-0001-0000-0000-000000000001')) + time '09:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'));

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select lives_ok(
  $q$ select public.mark_attendance('44444444-0001-0000-0000-000000000007','eeeeeeee-0001-0000-0000-000000000007','present') $q$,
  'Занятие today-3 отмечено и списано с абонемента 8 — фикстура для guard-тестов ниже');
reset role;

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;

-- 17. Заморозка, покрывающая today-3 (там уже списанная отметка) — отклонена.
select throws_ok(
  $q$ select public.freeze_subscription('88888888-0001-0000-0000-000000000008'::uuid,
        public.center_today('cccccccc-0001-0000-0000-000000000001') - 5,
        public.center_today('cccccccc-0001-0000-0000-000000000001') - 1) $q$,
  '22023', null, 'Заморозка задним числом поверх уже списанного занятия — guard отклоняет (раздел 7)');

-- 18. Заморозка С СЕГОДНЯШНЕГО дня — сегодняшнее занятие (today) ещё не
-- отмечено, но окно не задевает today-3: проходит без вопросов.
select lives_ok(
  $q$ select public.freeze_subscription('88888888-0001-0000-0000-000000000008'::uuid,
        public.center_today('cccccccc-0001-0000-0000-000000000001'),
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 7) $q$,
  'Заморозка с сегодняшнего дня не задевает списание трёхдневной давности — проходит');
reset role;

-- 19. Перенос УЖЕ отмеченного занятия (today-3, списано) внутрь текущего окна
-- заморозки (today..today+7) — ИЗВЕСТНЫЙ, не устранённый в этой миграции
-- пробел: reschedule_lesson не проверяет привязанные абонементы (раздел,
-- шапка файла — третье ребро инварианта).
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select lives_ok(
  $q$ select public.reschedule_lesson('44444444-0001-0000-0000-000000000007',
        ((public.center_today('cccccccc-0001-0000-0000-000000000001') + 2) + time '09:00') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001'),
        ((public.center_today('cccccccc-0001-0000-0000-000000000001') + 2) + time '09:45') at time zone public.center_timezone('cccccccc-0001-0000-0000-000000000001')) $q$,
  'ИЗВЕСТНЫЙ пробел (шапка файла): reschedule_lesson переносит уже списанное занятие внутрь окна заморозки без проверки');
reset role;


-- 20-24. Разморозка: не позже сегодня, отмена ещё не начавшейся -----------------------

-- Абонемент 9: заморозка НАЧАЛАСЬ (с сегодня, открытый конец) — для проверки
-- "будущий p_to отклонён". Абонемент 10 — ЕЩЁ НЕ началась (с today+10) — для
-- проверки "целиком отменить, а не снять датой". Разные абонементы намеренно:
-- если бы обе заморозки жили на одном, "ещё не началась" branch сработал бы
-- первым и до проверки будущего p_to дело бы не дошло вовсе.
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-000000000009','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000007','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 1, null);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-00000000000d','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000008','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 5, null);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;

-- 20. Заморозка УЖЕ НАЧАЛАСЬ (с сегодня, открытый конец) — снять будущей
-- датой нельзя: "разморозить" не планирует конец вперёд.
select public.freeze_subscription('88888888-0001-0000-0000-000000000009'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001'));
select throws_ok(
  $q$ select public.unfreeze_subscription('88888888-0001-0000-0000-000000000009'::uuid,
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 3) $q$,
  '22023', null, 'unfreeze_subscription с будущей датой отклонён у уже начавшейся заморозки (round2, находка 8)');

-- 21. Заморозка "с понедельника" (абонемент 10, ЕЩЁ не началась, открытый
-- конец) — снять её можно только целиком, не датой (той же будущей или
-- любой другой — она вообще не ищется по прошлой/сегодняшней дате).
select public.freeze_subscription('88888888-0001-0000-0000-00000000000d'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 10);
select lives_ok(
  $q$ select public.unfreeze_subscription('88888888-0001-0000-0000-00000000000d') $q$,
  'Ещё не начавшуюся БЕССРОЧНУЮ заморозку unfreeze_subscription отменяет целиком');
select is(public.subscription_state('88888888-0001-0000-0000-00000000000d'), 'active',
  'После отмены — снова active, а не всё ещё числится замороженным');

-- 22. После отмены — новую заморозку того же абонемента создать можно
-- (защёлка не видит отменённую как "незакрытую" благодаря isempty()).
select public.freeze_subscription('88888888-0001-0000-0000-00000000000d'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 15,
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 22);

-- 23. Эта новая заморозка — ДАТИРОВАННАЯ (с известным концом) и ещё не
-- началась: отменяем её тоже целиком (round5, находка 1 — initial lookup
-- должен находить не только upper_inf, но и ещё-не-начавшуюся датированную).
select lives_ok(
  $q$ select public.unfreeze_subscription('88888888-0001-0000-0000-00000000000d') $q$,
  'Ещё не начавшуюся ДАТИРОВАННУЮ заморозку unfreeze_subscription тоже отменяет целиком (round5, находка 1)');

-- 24. И снова можно заморозить — защёлка не залипла на отменённой датированной.
select lives_ok(
  $q$ select public.freeze_subscription('88888888-0001-0000-0000-00000000000d'::uuid,
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 1,
        public.center_today('cccccccc-0001-0000-0000-000000000001') + 8) $q$,
  'После второй отмены-до-начала защёлка снова не блокирует новую заморозку');
reset role;


-- 25-26. subscription_summary: границы текущей заморозки -----------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
-- Абонемент 1 (тест 1-3) на этот момент заморожен [today-2, today+5).
select is(
  (select freeze_to from public.subscription_summary('88888888-0001-0000-0000-000000000001')),
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 4,
  'subscription_summary.freeze_to — последний ЗАМОРОЖЕННЫЙ день (upper-1), не граница диапазона');
select ok(
  (select freeze_to from public.subscription_summary('88888888-0001-0000-0000-000000000002')) is null,
  'freeze_to = NULL для бессрочной заморозки (абонемент 2, allow_negative, "пока не разморозят")');
reset role;


-- 27-30. student_balance: истёкший не обгоняет заморожен-действующего ----------------

insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-00000000000a','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000009','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 4, 200000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 60, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20);
insert into public.subscriptions (id, center_id, student_id, payer_id, type_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at, ends_at) values
  ('88888888-0001-0000-0000-00000000000b','cccccccc-0001-0000-0000-000000000001','eeeeeeee-0001-0000-0000-000000000009','bbbbbbbb-0001-0000-0000-000000000001','77777777-0001-0000-0000-000000000001', 8, 400000, 50000, public.center_today('cccccccc-0001-0000-0000-000000000001') - 20, null);

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select public.freeze_subscription('88888888-0001-0000-0000-00000000000b'::uuid,
  public.center_today('cccccccc-0001-0000-0000-000000000001'),
  public.center_today('cccccccc-0001-0000-0000-000000000001') + 10);

-- 27. active_subscription_id — заморожен-но-действующий (...000b), не истёкший (...000a).
select is(
  (select active_subscription_id from public.student_balance where student_id = 'eeeeeeee-0001-0000-0000-000000000009'),
  '88888888-0001-0000-0000-00000000000b'::uuid,
  'active_subscription_id — заморожен-но-действующий абонемент, не истёкший (round4, находка 2)');
-- 28. state в витрине — 'frozen', видно напрямую владельцу.
select is(
  (select state from public.student_balance where student_id = 'eeeeeeee-0001-0000-0000-000000000009'),
  'frozen', 'student_balance.state = frozen для владельца — видно напрямую в витрине (раздел 10)');
reset role;

-- 29. Владелец чужого центра не видит student_balance этого ребёнка вовсе.
select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0001-0000-0000-000000000002');
set local role authenticated;
select is(
  (select count(*)::int from public.student_balance where student_id = 'eeeeeeee-0001-0000-0000-000000000009'),
  0, 'Владелец чужого центра не видит student_balance ребёнка центра А вовсе');
reset role;

-- 30. subscription_freeze_days абонемента 1 — ровно сумма его собственных
-- заморозок (7+7=14 от тестов 1-2), не задета соседними абонементами.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select is(public.subscription_freeze_days('88888888-0001-0000-0000-000000000001'), 14,
  'Дни заморозки абонемента 1: 7 (истёкшая) + 7 (текущая) = 14, ровно свои, не чужие');
reset role;


-- 31-34. Типы абонементов: пакеты без срока, защита проданных ------------------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;

-- 31. kind='lessons' с period_days — запрещено констрейнтом (продукт-решение 1).
select throws_ok(
  $q$ insert into public.subscription_types (center_id, name, service_id, kind, lessons_count, period_days, price_tiyin)
      values ('cccccccc-0001-0000-0000-000000000001','Пакет со сроком','99999999-0001-0000-0000-000000000001','lessons',8,30,300000) $q$,
  '23514', null, 'Пакет занятий не может иметь period_days — constraint из раздела 3');

-- 32. Тип 1 уже продан (использован во многих subscriptions выше) — менять
-- kind/period_days нельзя.
select throws_ok(
  $q$ update public.subscription_types set period_days = 10 where id = '77777777-0001-0000-0000-000000000001' $q$,
  '22023', null, 'kind/period_days проданного типа защищены триггером (раздел 3)');

-- 33. Но остальные поля того же типа — редактируются свободно.
select lives_ok(
  $q$ update public.subscription_types set name = 'Восемь занятий (перепродано)' where id = '77777777-0001-0000-0000-000000000001' $q$,
  'Имя проданного типа редактируется свободно — защита точечная, не общий revoke');

-- 34. Тип БЕЗ единого проданного абонемента — kind/period_days меняются свободно.
insert into public.subscription_types (id, center_id, name, service_id, kind, lessons_count, price_tiyin) values
  ('77777777-0001-0000-0000-000000000003','cccccccc-0001-0000-0000-000000000001','Новый пакет','99999999-0001-0000-0000-000000000001','lessons',5,250000);
select lives_ok(
  $q$ update public.subscription_types set kind = 'period', lessons_count = null, period_days = 14 where id = '77777777-0001-0000-0000-000000000003' $q$,
  'Тип без проданных абонементов — kind/period_days меняются свободно, триггер молчит');
reset role;


-- 35-37. Границы диапазона и нормализация 'infinity' ---------------------------------

-- 35. Верхняя граница диапазона исключающая: последний день внутри окна ещё
-- заморожен, день upper() уже нет.
select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select ok(
  public.subscription_current_freeze('88888888-0001-0000-0000-000000000001',
    public.center_today('cccccccc-0001-0000-0000-000000000001') + 4) is not null,
  'today+4 — ещё замороженный день внутри [today-2,today+5)');
select ok(
  public.subscription_current_freeze('88888888-0001-0000-0000-000000000001',
    public.center_today('cccccccc-0001-0000-0000-000000000001') + 5) is null,
  'today+5 — уже НЕ замороженный день: верхняя граница диапазона исключающая');
reset role;

-- 36. Нормализация 'infinity'-сентинела (раздел 1): в базе таких строк не
-- остаётся после миграции — заводим одну руками (как писала бы 0008) и
-- убеждаемся, что раздел 1 уже отработал до этой точки, то есть НОВЫЕ
-- строки в такой форме появиться не могут через штатный путь записи.
select ok(
  not exists (select 1 from public.subscription_freezes where upper(period) = 'infinity'::date),
  'Ни одна строка subscription_freezes не хранит верхнюю границу как дату ''infinity'' — только неограниченный upper');

-- 37. student_balance_pick — security invoker, грант нужен только чтобы
-- вьюха (тоже invoker) могла её вызвать от имени реального пользователя.
-- Прямой вызов специалистом не падает (не RPC с собственной проверкой
-- роли), но её СОДЕРЖИМОЕ для его собственного ученика — пусто: RLS
-- subscriptions (0008:249-257) не даёт teacher ни одной строки, точно так
-- же, как и через вьюху. Гарантия держится на том, что все колонки этой
-- функции приходят из subscriptions — см. комментарий в разделе 10.
select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0001-0000-0000-000000000001');
set local role authenticated;
select is(
  (select count(*)::int from public.student_balance_pick('eeeeeeee-0001-0000-0000-000000000001')),
  0, 'student_balance_pick для специалиста возвращает 0 строк даже для его собственного ученика — RLS subscriptions, не только фильтр на вьюхе');

select * from finish();
rollback;
