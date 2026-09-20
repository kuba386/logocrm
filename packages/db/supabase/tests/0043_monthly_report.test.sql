-- pgTAP: месячный отчёт родителю (0043).
--
-- Главное здесь — приватность и права. Отчёт уходит семье, поэтому в нём
-- не должно быть ни расшифровки голосового, ни SOAP, ни пометок
-- специалиста, ни комментария к отметке посещения. Проверяется не глазами:
-- в каждое закрытое поле кладётся уникальная строка-канарейка, и тест
-- ищет её во всём тексте отчёта.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(42);


-- Фикстура ------------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','61111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-rep@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','64444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-rep@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','65555555-5555-5555-5555-555555555555','authenticated','authenticated','teacher-idle-rep@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','67777777-7777-7777-7777-777777777777','authenticated','authenticated','parent-rep@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','62222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-rep@test.kg','','','','','','','','');

-- Пояс не бишкекский: границы месяца обязаны считаться по центру.
insert into public.centers (id, name, slug, settings) values
  ('6ccccccc-0000-0000-0000-00000000000a','Центр отчёта','centr-report','{"timezone":"Europe/Lisbon"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('6aaaaaaa-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','Ведущий'),
  ('6aaaaaaa-0000-0000-0000-000000000002','6ccccccc-0000-0000-0000-00000000000a','Без занятий');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('6bbbbbbb-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','Логопед',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('6ddddddd-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','Родитель','+996700000601');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('61111111-1111-1111-1111-111111111111','6ccccccc-0000-0000-0000-00000000000a','owner',    null, null),
  ('64444444-4444-4444-4444-444444444444','6ccccccc-0000-0000-0000-00000000000a','teacher','6aaaaaaa-0000-0000-0000-000000000001', null),
  ('65555555-5555-5555-5555-555555555555','6ccccccc-0000-0000-0000-00000000000a','teacher','6aaaaaaa-0000-0000-0000-000000000002', null),
  ('67777777-7777-7777-7777-777777777777','6ccccccc-0000-0000-0000-00000000000a','parent',   null, '6ddddddd-0000-0000-0000-000000000001'),
  ('62222222-2222-2222-2222-222222222222','6ccccccc-0000-0000-0000-00000000000a','registrar',null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('6eeeeeee-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','Айсулуу','6ddddddd-0000-0000-0000-000000000001'),
  ('6eeeeeee-0000-0000-0000-000000000002','6ccccccc-0000-0000-0000-00000000000a','Архивный','6ddddddd-0000-0000-0000-000000000001');

-- Различающий случай пояса. Лиссабон летом — UTC+1, то есть ВПЕРЕДИ UTC.
-- Значит отличает правильную реализацию от неправильной занятие, у
-- которого локальная дата БОЛЬШЕ UTC-даты: 1 сентября 00:30 по центру —
-- это 31 августа 23:30 UTC. Оно обязано попасть в СЕНТЯБРЬ.
--
-- Первая редакция теста брала 31.08 23:30+01 и утверждала, что «в UTC это
-- уже сентябрь». Это неверно: в UTC там 22:30 того же 31 августа, и
-- реализация, считающая по UTC или по поясу сессии, проходила ассерт
-- ровно так же, как правильная.
insert into public.lessons (id, center_id, teacher_id, student_id, service_id, status, starts_at, ends_at) values
  ('6fffffff-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','6aaaaaaa-0000-0000-0000-000000000001','6eeeeeee-0000-0000-0000-000000000001','6bbbbbbb-0000-0000-0000-000000000001','done','2026-09-10 10:00+01','2026-09-10 10:45+01'),
  ('6fffffff-0000-0000-0000-000000000002','6ccccccc-0000-0000-0000-00000000000a','6aaaaaaa-0000-0000-0000-000000000001','6eeeeeee-0000-0000-0000-000000000001','6bbbbbbb-0000-0000-0000-000000000001','done','2026-09-17 10:00+01','2026-09-17 10:45+01'),
  ('6fffffff-0000-0000-0000-000000000003','6ccccccc-0000-0000-0000-00000000000a','6aaaaaaa-0000-0000-0000-000000000001','6eeeeeee-0000-0000-0000-000000000001','6bbbbbbb-0000-0000-0000-000000000001','done','2026-09-01 00:30+01','2026-09-01 01:15+01'),
  -- Отменённое занятие с отметкой: отмена задним числом отметку не
  -- убирает (attendance не имеет deleted_at), но в отчёт оно попасть не
  -- должно.
  ('6fffffff-0000-0000-0000-000000000004','6ccccccc-0000-0000-0000-00000000000a','6aaaaaaa-0000-0000-0000-000000000001','6eeeeeee-0000-0000-0000-000000000001','6bbbbbbb-0000-0000-0000-000000000001','done','2026-09-24 10:00+01','2026-09-24 10:45+01');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

select public.tests_claims('61111111-1111-1111-1111-111111111111','6ccccccc-0000-0000-0000-00000000000a');

-- Канарейки: уникальные строки в каждом закрытом поле.
insert into public.attendance (center_id, lesson_id, student_id, status_id, comment)
select '6ccccccc-0000-0000-0000-00000000000a', l.id, '6eeeeeee-0000-0000-0000-000000000001',
       (select id from public.attendance_statuses
         where center_id = '6ccccccc-0000-0000-0000-00000000000a' and code = 'present'),
       'КАНАРЕЙКА-КОММЕНТАРИЙ-СТОЙКИ'
  from public.lessons l where l.id in (
    '6fffffff-0000-0000-0000-000000000001','6fffffff-0000-0000-0000-000000000002',
    '6fffffff-0000-0000-0000-000000000003','6fffffff-0000-0000-0000-000000000004');

insert into public.goals (id, center_id, student_id, stage_id, title, status) values
  ('6bbb0000-0000-0000-0000-000000000001','6ccccccc-0000-0000-0000-00000000000a','6eeeeeee-0000-0000-0000-000000000001',
   (select id from public.goal_stages where center_id = '6ccccccc-0000-0000-0000-00000000000a' and code = 'syllables'),
   'Р в слогах','active');

-- Точки в августе и октябре: без фильтра по периоду они сдвинут первую и
-- последнюю оценку сентября, и регрессия «отчёт за сентябрь показывает
-- ноябрьскую оценку» пройдёт незамеченной.
insert into public.goal_progress (center_id, goal_id, lesson_id, date, score, note) values
  ('6ccccccc-0000-0000-0000-00000000000a','6bbb0000-0000-0000-0000-000000000001',null,'2026-08-20',10,null),
  ('6ccccccc-0000-0000-0000-00000000000a','6bbb0000-0000-0000-0000-000000000001','6fffffff-0000-0000-0000-000000000001','2026-09-10',40,'КАНАРЕЙКА-ПОМЕТКА-СПЕЦИАЛИСТА'),
  ('6ccccccc-0000-0000-0000-00000000000a','6bbb0000-0000-0000-0000-000000000001','6fffffff-0000-0000-0000-000000000002','2026-09-17',70,null),
  ('6ccccccc-0000-0000-0000-00000000000a','6bbb0000-0000-0000-0000-000000000001',null,'2026-10-05',90,null);

insert into public.lesson_notes
  (center_id, lesson_id, student_id, teacher_id, raw_transcript, soap, parent_summary, status)
values
  ('6ccccccc-0000-0000-0000-00000000000a','6fffffff-0000-0000-0000-000000000001','6eeeeeee-0000-0000-0000-000000000001',
   '6aaaaaaa-0000-0000-0000-000000000001','КАНАРЕЙКА-РАСШИФРОВКА',
   '{"plan":"КАНАРЕЙКА-СОАП"}'::jsonb,'Хорошо поработали над слогами.','approved'),
  ('6ccccccc-0000-0000-0000-00000000000a','6fffffff-0000-0000-0000-000000000002','6eeeeeee-0000-0000-0000-000000000001',
   '6aaaaaaa-0000-0000-0000-000000000001',null,'{}'::jsonb,'КАНАРЕЙКА-ЧЕРНОВИК','draft');

-- Отмена задним числом: отметка уже стоит, и attendance её не теряет —
-- у него нет deleted_at (0009, сознательно). Ровно поэтому отчёт обязан
-- фильтровать по статусу занятия сам.
update public.lessons set status = 'cancelled' where id = '6fffffff-0000-0000-0000-000000000004';

update public.students set deleted_at = now() where id = '6eeeeeee-0000-0000-0000-000000000002';


-- Приватность: ни одна канарейка не попала в отчёт -----------------------------------------------

set local role authenticated;

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    not like '%КАНАРЕЙКА-РАСШИФРОВКА%',
  'Расшифровки голосового в отчёте нет');

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    not like '%КАНАРЕЙКА-СОАП%',
  'SOAP в отчёте нет');

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    not like '%КАНАРЕЙКА-ПОМЕТКА-СПЕЦИАЛИСТА%',
  'Внутренней пометки к оценке цели в отчёте нет');

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    not like '%КАНАРЕЙКА-КОММЕНТАРИЙ-СТОЙКИ%',
  'Комментария к отметке посещения в отчёте нет');

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    not like '%КАНАРЕЙКА-ЧЕРНОВИК%',
  'Неутверждённая заметка в отчёт не попадает');

select ok(
  public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01')::text
    like '%Хорошо поработали над слогами%',
  'А утверждённое резюме — попадает');


-- Состав колонок узких функций по каталогу --------------------------------------------------------

select is(
  pg_get_function_result('public.student_attendance_brief(uuid,date,date)'::regprocedure),
  'TABLE(lesson_at timestamp with time zone, status_name text, counts_absence boolean)',
  'В посещаемости нет ни цены, ни абонемента, ни комментария — физически');

select ok(
  pg_get_function_result('public.student_goal_dynamics_brief(uuid,date,date)'::regprocedure) not like '%note%',
  'В динамике целей нет пометки специалиста');


-- Границы месяца в поясе центра -------------------------------------------------------------------

select is(
  (public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') ->> 'lessons_total')::int,
  3, 'Сентябрь: три занятия. Занятие 1 сентября 00:30 по центру — сентябрьское, хотя в UTC это 31 августа');

select is(
  (public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-08-01') ->> 'lessons_total')::int,
  0, 'И в августе его нет: считаем по поясу центра, а не по UTC и не по поясу сессии');

select is(
  (select count(*)::int from public.student_attendance_brief('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','2026-09-30')),
  3, 'Отменённое занятие в посещаемость не попало, хотя отметка по нему осталась');

select is(
  (public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-17') ->> 'period_month'),
  '2026-09-01', 'Месяц нормализуется: 17-е число даёт тот же период, что 1-е');


-- Динамика целей ----------------------------------------------------------------------------------

select is(
  (select score_first from public.student_goal_dynamics_brief('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','2026-09-30')),
  40, 'Первая оценка периода');

select is(
  (select score_last from public.student_goal_dynamics_brief('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','2026-09-30')),
  70, 'Последняя оценка периода — октябрьская 90 её не сдвинула');

select is(
  (select points from public.student_goal_dynamics_brief('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','2026-09-30')),
  2, 'И точек ровно две: августовская и октябрьская вне периода');

select ok(
  jsonb_array_length(public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') -> 'goals') = 1,
  'Массив целей в отчёте непуст — иначе канарейка по пометке проходила бы вхолостую');

reset role;


-- Права на чтение ----------------------------------------------------------------------------------

select public.tests_claims('67777777-7777-7777-7777-777777777777','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(
  (public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') ->> 'lessons_total') = '2',
  'Родитель своего ребёнка отчёт читает');
select throws_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') $q$,
  '42501', null,
  'Но отправить его себе не может — рассылка это решение центра');
reset role;

select public.tests_claims('62222222-2222-2222-2222-222222222222','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') $q$,
  '42501', null,
  'Регистратору клиника не положена — и отчёт тоже');
select is(
  (select count(*)::int from public.student_attendance_brief('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','2026-09-30')),
  0, 'И узкая функция посещаемости ему молчит');
reset role;

select public.tests_claims('65555555-5555-5555-5555-555555555555','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') $q$,
  '42501', null,
  'Специалист без занятий с ребёнком в этом месяце не отправляет');
reset role;


-- Архивный ребёнок ------------------------------------------------------------------------------

select public.tests_claims('61111111-1111-1111-1111-111111111111','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select throws_ok(
  $q$ select public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000002','2026-09-01') $q$,
  '42704', null,
  'По архивному ребёнку — честный отказ, а не пустая страница');

select throws_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-07-01') $q$,
  '22023', null,
  'Пустой месяц не рассылается: «0 занятий» читается как поломка');


-- Отправка и повтор -------------------------------------------------------------------------------

select lives_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01','От специалиста: молодцы') $q$,
  'Владелец отправляет отчёт');

select is(
  (select sent_count from public.monthly_reports where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  1, 'Счётчик отправок — один');

select is(
  (select count(*)::int from public.events where type = 'report.monthly_ready'),
  1, 'Событие ровно одно');

select ok(
  (select summary_text like '%Занятий: 2, пропусков: 0%' from public.monthly_reports
    where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  'Снимок текста заморожен в реестре');

select ok(
  (select summary_text like '%От специалиста: молодцы%' from public.monthly_reports
    where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  'Комментарий специалиста попал в выжимку');

select throws_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-17') $q$,
  '23505', null,
  'Повтор без подтверждения отбивается — и 17-е число это тот же месяц');

select is(
  (select count(*)::int from public.events where type = 'report.monthly_ready'),
  1, 'Второго события не появилось');

select lives_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01', null, true) $q$,
  'С явным подтверждением отправка повторяется');

select is(
  (select sent_count from public.monthly_reports where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  2, 'И счётчик вырос до двух');

select throws_ok(
  $q$ insert into public.monthly_reports (center_id, student_id, period_month)
      values ('6ccccccc-0000-0000-0000-00000000000a','6eeeeeee-0000-0000-0000-000000000001','2026-10-01') $q$,
  '42501', null,
  'Реестр закрыт на запись даже владельцу — иначе обнуление счётчика вернуло бы вторую рассылку');
reset role;


-- Доставка ------------------------------------------------------------------------------------------

select is(
  (select count(*)::int from public.notification_event_types where event_type = 'report.monthly_ready'),
  1, 'Тип события в белом списке — без него шаблон не вставить');

select is(
  (select count(*)::int from public.message_templates
    where event_type = 'report.monthly_ready' and center_id is null),
  2, 'Шаблона два: родитель без Telegram иначе не получил бы ничего');


-- Положительный путь специалиста и ветка доставки ---------------------------------------------------

select public.tests_claims('64444444-4444-4444-4444-444444444444','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select lives_ok(
  $q$ select public.send_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01', 'Летом — по карточкам', true) $q$,
  'Специалист с занятиями в этом месяце отправляет — иначе реализация, отказывающая всем, прошла бы тест');
reset role;

select public.tests_claims('61111111-1111-1111-1111-111111111111','6ccccccc-0000-0000-0000-00000000000a');
set local role authenticated;
select ok(
  (select summary_text like '%Летом — по карточкам%' from public.monthly_reports
    where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  'Новый комментарий попал в снимок — v_row после правки перечитан');

select ok(
  (select stats ? 'lessons_total' and stats ? 'absences' and stats ? 'goals'
     from public.monthly_reports where student_id = '6eeeeeee-0000-0000-0000-000000000001'),
  'Снимок чисел записан');

select ok(
  (public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') -> 'sent') is not null,
  'Читалка отдаёт и то, что реально ушло родителю, а не только пересчёт');
reset role;

select public.tests_claims(null, null);
select is(
  (select subject_id from public.event_messages(
     (select last_event_id from public.monthly_reports
       where student_id = '6eeeeeee-0000-0000-0000-000000000001')) limit 1),
  '6eeeeeee-0000-0000-0000-000000000001'::uuid,
  'Ветка доставки возвращает ребёнка — без него триггер 0035 уронил бы каждое сообщение');


-- Чужой центр ---------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values ('00000000-0000-0000-0000-000000000000','69999999-9999-9999-9999-999999999999','authenticated','authenticated','owner-b-rep@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('6ccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b-report');
insert into public.memberships (user_id, center_id, role) values
  ('69999999-9999-9999-9999-999999999999','6ccccccc-0000-0000-0000-00000000000b','owner');

select public.tests_claims('69999999-9999-9999-9999-999999999999','6ccccccc-0000-0000-0000-00000000000b');
set local role authenticated;
select is(
  (select count(*)::int from public.monthly_reports), 0,
  'Владелец чужого центра не видит ни одной строки реестра');
select throws_ok(
  $q$ select public.student_monthly_report('6eeeeeee-0000-0000-0000-000000000001','2026-09-01') $q$,
  '42501', null,
  'И отчёт по чужому ребёнку не читает');
reset role;

select * from finish();

rollback;
