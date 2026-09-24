-- pgTAP: глобальный поиск (0062) — границы выдачи по ролям = RLS, телефон в
-- любом формате, ближайшее занятие, порядок самой функции, край входа,
-- забор колонок и природы функции (SECURITY INVOKER).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select * from no_plan();

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated','owner-a-0062@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated','registrar-a-0062@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated','finance-a-0062@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated','teacher-a-0062@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','55555555-5555-5555-5555-555555555555','authenticated','authenticated','parent-a-0062@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','owner-b-0062@test.kg','','','','','','','','');

insert into public.centers (id, name, slug) values
  ('cccccccc-0000-0000-0000-000000000062','Центр А 0062','centr-a-0062'),
  ('cccccccc-0000-0000-0000-000000000063','Центр Б 0062','centr-b-0062');

insert into public.teachers (id, center_id, full_name, profile_id) values
  ('aaaaaaaa-0000-0000-0000-000000000621','cccccccc-0000-0000-0000-000000000062','Специалист Один','44444444-4444-4444-4444-444444444444'),
  ('aaaaaaaa-0000-0000-0000-000000000622','cccccccc-0000-0000-0000-000000000062','Специалист Два', null),
  ('aaaaaaaa-0000-0000-0000-000000000631','cccccccc-0000-0000-0000-000000000063','Специалист Б',   null);

-- phone_alt хранится «как ввели» — поиск обязан нормализовать обе стороны.
-- Номер P4 начинается так же, как хвост phone_alt у P1 («555111…»), —
-- вхождение не должно склеивать двух родителей на точном номере.
insert into public.payers (id, center_id, full_name, phone, phone_alt, deleted_at) values
  ('dddddddd-0000-0000-0000-000000000621','cccccccc-0000-0000-0000-000000000062','Гульнара Иванова','+996700123456','0555 111 222', null),
  ('dddddddd-0000-0000-0000-000000000622','cccccccc-0000-0000-0000-000000000062','Семён Петров',    '+996700999888', null, null),
  ('dddddddd-0000-0000-0000-000000000623','cccccccc-0000-0000-0000-000000000062','Удалённый Плательщик','+996700777666', null, now()),
  ('dddddddd-0000-0000-0000-000000000624','cccccccc-0000-0000-0000-000000000062','Только Архивный', '+996555111333', null, null),
  ('dddddddd-0000-0000-0000-000000000631','cccccccc-0000-0000-0000-000000000063','Плательщик Б',    '+996700123456', null, null);

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id, birth_date, status, deleted_at) values
  ('eeeeeeee-0000-0000-0000-000000000621','cccccccc-0000-0000-0000-000000000062','Айжан Токтосунова','dddddddd-0000-0000-0000-000000000621','aaaaaaaa-0000-0000-0000-000000000621','2019-03-01','active',   null),
  ('eeeeeeee-0000-0000-0000-000000000622','cccccccc-0000-0000-0000-000000000062','Семён Иванов',     'dddddddd-0000-0000-0000-000000000622','aaaaaaaa-0000-0000-0000-000000000622', null,        'active',   null),
  ('eeeeeeee-0000-0000-0000-000000000623','cccccccc-0000-0000-0000-000000000062','Архивная Айжан',   'dddddddd-0000-0000-0000-000000000621','aaaaaaaa-0000-0000-0000-000000000621', null,        'archived', null),
  ('eeeeeeee-0000-0000-0000-000000000624','cccccccc-0000-0000-0000-000000000062','Удалённая Айжан',  'dddddddd-0000-0000-0000-000000000621','aaaaaaaa-0000-0000-0000-000000000621', null,        'active',   now()),
  ('eeeeeeee-0000-0000-0000-000000000625','cccccccc-0000-0000-0000-000000000062','Бекзат Асанов',    'dddddddd-0000-0000-0000-000000000622','aaaaaaaa-0000-0000-0000-000000000622', null,        'active',   null),
  -- Порядок самой функции: архивный с префиксом, активный с вхождением, пауза с префиксом.
  ('eeeeeeee-0000-0000-0000-000000000626','cccccccc-0000-0000-0000-000000000062','Нурлан Кыдыров',   'dddddddd-0000-0000-0000-000000000622','aaaaaaaa-0000-0000-0000-000000000622', null,        'archived', null),
  ('eeeeeeee-0000-0000-0000-000000000627','cccccccc-0000-0000-0000-000000000062','Мария Нурланова',  'dddddddd-0000-0000-0000-000000000622','aaaaaaaa-0000-0000-0000-000000000622', null,        'active',   null),
  ('eeeeeeee-0000-0000-0000-000000000628','cccccccc-0000-0000-0000-000000000062','Нурлан Паузов',    'dddddddd-0000-0000-0000-000000000622','aaaaaaaa-0000-0000-0000-000000000622', null,        'paused',   null),
  ('eeeeeeee-0000-0000-0000-000000000629','cccccccc-0000-0000-0000-000000000062','Ребёнок Архивного','dddddddd-0000-0000-0000-000000000624','aaaaaaaa-0000-0000-0000-000000000622', null,        'archived', null),
  ('eeeeeeee-0000-0000-0000-000000000631','cccccccc-0000-0000-0000-000000000063','Айжан Б',          'dddddddd-0000-0000-0000-000000000631','aaaaaaaa-0000-0000-0000-000000000631', null,        'active',   null);

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000062','owner',     null, null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000062','registrar', null, null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000062','finance',   null, null),
  ('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000062','teacher',   'aaaaaaaa-0000-0000-0000-000000000621', null),
  ('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000062','parent',    null, 'dddddddd-0000-0000-0000-000000000621'),
  ('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-000000000063','owner',     null, null);

insert into public.groups (id, center_id, name, teacher_id) values
  ('99990000-0000-0000-0000-000000000621','cccccccc-0000-0000-0000-000000000062','Малыши','aaaaaaaa-0000-0000-0000-000000000622');
insert into public.group_students (center_id, group_id, student_id) values
  ('cccccccc-0000-0000-0000-000000000062','99990000-0000-0000-0000-000000000621','eeeeeeee-0000-0000-0000-000000000625');

-- Занятия Айжан: L7 идёт прямо сейчас (Специалист Два) — «ближайшее» для
-- владельца и родителя; L2 (+1 день, Два) и L1 (+2 дня, Один) — для
-- специалиста Один видно только L1; L4 отменено (+12 ч), L5 прошло.
-- L3 — Семён у Специалиста Один (teacher_teaches_student). L6 — группа
-- «Малыши» с Бекзатом; потом Бекзат выйдет из группы (group_students.left_at
-- → триггер удалит строку lp).
insert into public.lessons (id, center_id, teacher_id, student_id, group_id, status, starts_at, ends_at) values
  ('44440000-0000-0000-0000-000000000621','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000621','eeeeeeee-0000-0000-0000-000000000621', null, 'planned',   now() + interval '2 days',   now() + interval '2 days 45 minutes'),
  ('44440000-0000-0000-0000-000000000622','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000622','eeeeeeee-0000-0000-0000-000000000621', null, 'planned',   now() + interval '1 day',    now() + interval '1 day 45 minutes'),
  ('44440000-0000-0000-0000-000000000623','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000621','eeeeeeee-0000-0000-0000-000000000622', null, 'planned',   now() + interval '3 days',   now() + interval '3 days 45 minutes'),
  ('44440000-0000-0000-0000-000000000624','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000621','eeeeeeee-0000-0000-0000-000000000621', null, 'cancelled', now() + interval '12 hours', now() + interval '12 hours 45 minutes'),
  ('44440000-0000-0000-0000-000000000625','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000621','eeeeeeee-0000-0000-0000-000000000621', null, 'planned',   now() - interval '1 day',    now() - interval '1 day' + interval '45 minutes'),
  ('44440000-0000-0000-0000-000000000626','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000622', null, '99990000-0000-0000-0000-000000000621', 'planned', now() + interval '1 day 2 hours', now() + interval '1 day 2 hours 45 minutes'),
  ('44440000-0000-0000-0000-000000000627','cccccccc-0000-0000-0000-000000000062','aaaaaaaa-0000-0000-0000-000000000622','eeeeeeee-0000-0000-0000-000000000621', null, 'planned',   now() - interval '10 minutes', now() + interval '35 minutes');
-- Бекзат вышел из группы — тем путём, каким это делает приложение.
update public.group_students set left_at = current_date
 where student_id = 'eeeeeeee-0000-0000-0000-000000000625';

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;


-- Владелец: имя, имя плательщика, архив, порядок, телефон во всех форматах ---------------

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-000000000062');
set local role authenticated;

select is(
  (select array_agg(title order by rank, title) from public.global_search('айжан') where kind = 'student'),
  array['Айжан Токтосунова', 'Архивная Айжан'],
  'Владелец: по части ФИО — активная и архивная, без удалённой и без чужого центра');
select is(
  (select array_agg(title order by rank) from public.global_search('нурлан') where kind = 'student'),
  array['Нурлан Паузов', 'Мария Нурланова', 'Нурлан Кыдыров'],
  'Порядок самой функции по rank: префикс (пауза) → вхождение (активная) → архивный, даже с префиксом (Р5)');
select is(
  (select array_agg(status order by rank) from public.global_search('нурлан') where kind = 'student'),
  array['paused', 'active', 'archived'],
  'Статус отдаётся для всех — paused и archived видны в выдаче');
select is(
  (select subtitle from public.global_search('токтосун') where kind = 'student'),
  'Гульнара Иванова', 'subtitle ученика — имя плательщика через payer_display_name');
select is(
  (select extra from public.global_search('токтосун') where kind = 'student'),
  public.age_years('2019-03-01')::text, 'extra ученика — возраст');
select is(
  (select count(*)::int from public.global_search('гульнара') where kind = 'student'),
  2, 'По имени плательщика находятся её дети');
select is(
  (select title from public.global_search('гульнара') where kind = 'payer'),
  'Гульнара Иванова', '…и сама карточка плательщика');
select is(
  (select extra from public.global_search('гульнара') where kind = 'payer'),
  'Айжан Токтосунова, Архивная Айжан', 'extra плательщика — все живые дети, включая архивных');
select is(
  (select extra from public.global_search('только архивный') where kind = 'payer'),
  'Ребёнок Архивного', 'Плательщик с единственным архивным ребёнком — не «детей нет»');

select is(
  (select array_agg(kind || ':' || title order by kind, title) from public.global_search('0700 123 456') where kind in ('payer','student')),
  array['payer:Гульнара Иванова', 'student:Айжан Токтосунова', 'student:Архивная Айжан'],
  'Полный номер в местном формате — плательщик и её дети');
select is((select rank from public.global_search('+996 (700) 12-34-56') where kind = 'payer'), 0,
  'Точное совпадение телефона — ранг 0');
select is((select title from public.global_search('00996700123456') where kind = 'payer'), 'Гульнара Иванова',
  'Международная запись с двумя нулями');
select is((select title from public.global_search('123456') where kind = 'payer'), 'Гульнара Иванова', 'Хвост номера');
select is((select title from public.global_search('07001234') where kind = 'payer'), 'Гульнара Иванова', 'Начало номера с ведущим нулём (Р4)');
select is(
  (select array_agg(title order by title) from public.global_search('555 111 222') where kind = 'payer'),
  array['Гульнара Иванова'], 'phone_alt в сыром формате — тоже ищется, и только он: «555111333» другого плательщика не склеивается');
select is(
  (select array_agg(title order by title) from public.global_search('555111') where kind = 'payer'),
  array['Гульнара Иванова', 'Только Архивный'], 'Общее начало номера — оба, это вхождение');
select is((select count(*)::int from public.global_search('777666')), 0, 'Удалённый плательщик не находится ни по номеру…');
select is((select count(*)::int from public.global_search('удалённ')), 0, '…ни по имени; удалённый ученик — тоже нет');
select is((select count(*)::int from public.global_search('123')), 0, 'Три цифры — не телефон и не имя');

-- «семен» — это и ученик Семён Иванов, и плательщик Семён Петров, а значит
-- и все дети Петрова (поиск по имени плательщика) с их занятиями.
select is(
  (select array_agg(title order by title) from public.global_search('семен') where kind = 'payer'),
  array['Семён Петров'], '«ё»/«е» — одно и то же: плательщик (Р7)');
select ok(
  'Семён Иванов' = any (select title from public.global_search('семен') where kind = 'student'),
  '…и ученик');
select is(
  (select count(*)::int from public.global_search('СЕМЁН')),
  (select count(*)::int from public.global_search('семен')),
  'Регистр кириллицы не важен — та же выдача');


-- Ближайшее занятие ---------------------------------------------------------------------

select is((select count(*)::int from public.global_search('токтосун') where kind = 'lesson'), 1,
  'Ровно одно занятие на ребёнка');
select is(
  (select id from public.global_search('токтосун') where kind = 'lesson'),
  '44440000-0000-0000-0000-000000000627',
  'Идущее прямо сейчас занятие — ближайшее (ends_at >= now()); отменённое и прошедшее — нет');
select is((select subtitle from public.global_search('токтосун') where kind = 'lesson'), 'Специалист Два',
  'subtitle занятия — специалист, который ведёт');
select is(
  (select week_start from public.global_search('токтосун') where kind = 'lesson'),
  date_trunc('week', ((now() - interval '10 minutes') at time zone 'Asia/Bishkek')::date)::date,
  'week_start — понедельник недели занятия в поясе центра (Р6)');
select is((select count(*)::int from public.global_search('архивная') where kind = 'lesson'), 0,
  'У архивной занятий нет');
select is((select count(*)::int from public.global_search('бекзат') where kind = 'student'), 1, 'Бекзат находится…');
select is((select count(*)::int from public.global_search('бекзат') where kind = 'lesson'), 0,
  '…но занятие группы, из которой он вышел (group_students.left_at → триггер), не выдаётся (Р3)');
select is((select count(*)::int from public.global_search('малыш')), 0, 'Групп в выдаче нет (Р12)');


-- Край входа: пусто, не исключение --------------------------------------------------------

select lives_ok($q$ select * from public.global_search(null) $q$, 'null — не падает');
select is((select count(*)::int from public.global_search(null)), 0, 'null — пусто');
select is((select count(*)::int from public.global_search('')), 0, 'пусто — пусто');
select is((select count(*)::int from public.global_search('а')), 0, 'один символ — пусто');
select is((select count(*)::int from public.global_search('%%')), 0, '«%%» экранируется — не весь центр');
select is((select count(*)::int from public.global_search('__')), 0, '«__» экранируется');
select lives_ok($q$ select * from public.global_search('\\') $q$, 'обратный слеш — не падает');
select is((select count(*)::int from public.global_search('айжан', null) where kind = 'student'), 2, 'p_limit null — дефолт, не «без лимита»');
select is((select count(*)::int from public.global_search('айжан', 0) where kind = 'student'), 1, 'p_limit 0 — clamp до 1');
select is((select count(*)::int from public.global_search('айжан', -5) where kind = 'student'), 1, 'p_limit −5 — clamp до 1');
select lives_ok($q$ select * from public.global_search('айжан', 100000) $q$, 'p_limit 100000 — clamp до 20, без ошибки');
reset role;


-- Специалист: только свои ученики, без телефона -------------------------------------------

select public.tests_claims('44444444-4444-4444-4444-444444444444','cccccccc-0000-0000-0000-000000000062');
set local role authenticated;
select is(
  (select array_agg(title order by title) from public.global_search('айжан') where kind = 'student'),
  array['Айжан Токтосунова', 'Архивная Айжан'],
  'teacher: свои (primary) ученики, удалённой нет');
select is((select subtitle from public.global_search('токтосун') where kind = 'student'), 'Гульнара Иванова',
  'teacher: имя плательщика своего ученика — как в students_teacher_view');
select is((select count(*)::int from public.global_search('гульнара') where kind = 'student'), 2,
  'teacher: находит по имени плательщика — ровно как видит его в списке (ветка payer_display_name, Р11)');
select is((select count(*)::int from public.global_search('гульнара') where kind = 'payer'), 0,
  'teacher: карточки плательщика в выдаче нет — payers ему не читаемы');
select is((select count(*)::int from public.global_search('0700123456')), 0,
  'teacher: по телефону — ноль строк любого вида');
select is((select title from public.global_search('семён') where kind = 'student'), 'Семён Иванов',
  'teacher: ученик другого специалиста, с которым есть занятие (teacher_teaches_student), находится');
select is((select subtitle from public.global_search('семён') where kind = 'student'), null::text,
  '…но имя его плательщика — null (payer_display_name отдаёт только плательщиков primary-учеников)');
select is((select count(*)::int from public.global_search('бекзат')), 0, 'teacher: чужой ученик без занятий — нет');
select is(
  (select id from public.global_search('токтосун') where kind = 'lesson'),
  '44440000-0000-0000-0000-000000000621',
  'teacher: ближайшее из ВИДИМЫХ ему занятий — L1 (своё, +2 дня), а не L7/L2 другого специалиста');
reset role;


-- Родитель: только свои дети и своя карточка -------------------------------------------------

select public.tests_claims('55555555-5555-5555-5555-555555555555','cccccccc-0000-0000-0000-000000000062');
set local role authenticated;
select is(
  (select array_agg(title order by title) from public.global_search('айжан') where kind = 'student'),
  array['Айжан Токтосунова', 'Архивная Айжан'], 'parent: только свои дети');
select is((select count(*)::int from public.global_search('семён')), 0, 'parent: чужой ребёнок и чужой плательщик — нет');
select is((select title from public.global_search('0700123456') where kind = 'payer'), 'Гульнара Иванова',
  'parent: своя карточка по телефону (payers_read_self)');
select is((select count(*)::int from public.global_search('гульнара') where kind = 'student'), 2,
  'parent: дети по имени плательщика — через payers_read_self (name_hit)');
select is(
  (select id from public.global_search('токтосун') where kind = 'lesson'),
  '44440000-0000-0000-0000-000000000627', 'parent: ближайшее занятие ребёнка (parent_of_lesson) — идущее сейчас');
reset role;


-- Бухгалтер — пусто (Р1); регистратор — как владелец; чужой центр --------------------------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-000000000062');
set local role authenticated;
select is((select count(*)::int from public.global_search('айжан')), 0,
  'finance: пусто — у роли нет политик на students/payers (0031), её список рисуют definer-RPC; поле в UI не показывается (Р1)');
reset role;

select public.tests_claims('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-000000000062');
set local role authenticated;
select is((select count(*)::int from public.global_search('айжан') where kind = 'student'), 2, 'registrar: ученики как у владельца');
select is((select title from public.global_search('3456') where kind = 'payer'), 'Гульнара Иванова', 'registrar: телефон ищется');
reset role;

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-000000000063');
set local role authenticated;
select is(
  (select array_agg(kind || ':' || title order by kind, title) from public.global_search('0700123456')),
  array['payer:Плательщик Б', 'student:Айжан Б'],
  'Владелец центра Б по тому же номеру видит только своих (ADR-002)');
select is((select count(*)::int from public.global_search('токтосун')), 0, '…и ребёнка центра А не находит');
reset role;


-- Забор: колонки, природа функции, гранты ------------------------------------------------------

select is(
  pg_get_function_result('public.global_search(text, integer)'::regprocedure),
  'TABLE(kind text, id uuid, title text, subtitle text, extra text, status text, starts_at timestamp with time zone, week_start date, rank integer)',
  'Набор колонок выдачи зафиксирован — телефон ребёнка, заметки и т.п. не проскочат молча');
select ok(
  not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'global_search'),
  'global_search — SECURITY INVOKER: definer открыл бы всех детей всем ролям (Р10)');
select ok(
  has_function_privilege('authenticated', 'public.global_search(text,integer)', 'EXECUTE'),
  'authenticated исполняет');
select ok(
  not has_function_privilege('anon', 'public.global_search(text,integer)', 'EXECUTE')
  and not has_function_privilege('public', 'public.global_search(text,integer)', 'EXECUTE'),
  'anon и public — нет');

select * from finish();

rollback;
