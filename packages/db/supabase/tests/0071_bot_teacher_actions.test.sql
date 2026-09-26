-- pgTAP: бот — посещение кнопками и заметка текстом (0071).
--
-- Заборы (до любого set role): шесть bot_*-функций исполняет только
-- bot_worker; помощники, emit_event_internal и тела триггеров посещения —
-- никто; bot_pending_actions без грантов и политик, под readonly guard, в
-- deny-list экспорта, все FK покрыты непартиальными btree (конвенция 0069).
-- Раздел 8б — находки второго раунда ревью: межцентровая изоляция (42704
-- без оракула существования, чужой ребёнок на групповом), чужой черновик
-- не дописывается, заметка owner без карточки специалиста, «ждём диктовку»
-- держится до черновика ИИ и снимается его провалом, два чата — два
-- контекста, ответ на устаревший ForceReply-промпт отвергается.
-- Главное, что ловит этот файл (блокер первого раунда ревью): отметка из
-- контура без сессии ПРОХОДИТ и даёт те же события, что экран —
-- attendance.marked / no_subscription / subscription.low_balance — потому
-- что триггеры посещения теперь эмитят через emit_event_internal, а не
-- через emit_event с гейтом auth.uid(). Отдельно — безсессионный insert в
-- attendance от postgres, чтобы отличить дыру эмиттера от дыры RPC.
-- Поведение: bot_today отдаёт can_mark/can_note по ролям и starts_local в
-- поясе центра; arm → (pick) → mark/write; тот же статус повторно —
-- changed=false без новых событий; другой статус — отказ, контекст жив;
-- групповое занятие требует выбора ребёнка, чужой/архивный ребёнок — отказ;
-- не сегодня / не началось / нет прав / нет контекста / протух контекст;
-- заметка: created_by = пользователь чата и автор УТВЕРЖДАЕТ её с экрана
-- (0041 Р2), дописывание, утверждённая — 23514, живая диктовка — отказ,
-- пусто/2001 знак — 22023; read-only: истёкший и помеченный на удаление
-- центр — PT402 с разными текстами; закрытый месяц — 22023 и в боте.
--
-- reset role не сбрасывает request.jwt.claims — tests_claims() явно.
-- Занятия «сегодня» — в поясе, где сейчас день (приём 0033): иначе прогон
-- CI около полуночи UTC сдвинул бы дату.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(89);


-- 1. Заборы по каталогу ---------------------------------------------------------------------------

select ok(
  (select bool_and(has_function_privilege('bot_worker', f, 'EXECUTE')
                   and not has_function_privilege('authenticated', f, 'EXECUTE')
                   and not has_function_privilege('anon', f, 'EXECUTE')
                   and not has_function_privilege('service_role', f, 'EXECUTE')
                   and not has_function_privilege('public', f, 'EXECUTE'))
     from unnest(array[
       'public.bot_today(bigint)', 'public.bot_arm_action(bigint,text,uuid)', 'public.bot_pick_student(bigint,uuid)',
       'public.bot_bind_prompt(bigint,bigint)',
       'public.bot_mark_attendance(bigint,uuid)', 'public.bot_write_note(bigint,text,bigint)']) f),
  'Шесть функций бота исполняет только bot_worker');

select ok(
  (select bool_and(not has_function_privilege('bot_worker', f, 'EXECUTE')
                   and not has_function_privilege('authenticated', f, 'EXECUTE')
                   and not has_function_privilege('anon', f, 'EXECUTE')
                   and not has_function_privilege('service_role', f, 'EXECUTE')
                   and not has_function_privilege('public', f, 'EXECUTE'))
     from unnest(array[
       'public.emit_event_internal(text,jsonb,uuid)', 'public.bot_lesson_rights(uuid,uuid)',
       'public.bot_assert_writable(uuid,uuid)', 'public.bot_voice_pending(uuid,uuid)',
       'public.bot_lesson_participants(uuid)',
       'public.attendance_recalc_trigger()', 'public.check_absent_streak(uuid,uuid,uuid)']) f),
  'emit_event_internal, помощники и тела триггеров посещения — ни у одной роли, включая bot_worker и service_role (Р19)');

select ok(
  exists (select 1 from public.export_center_excluded_tables() where table_name = 'bot_pending_actions')
  and not exists (select 1 from public.export_center_tables() where table_name = 'bot_pending_actions')
  and exists (select 1 from public.export_center_excluded_tables() where table_name = 'assistant_requests'),
  'bot_pending_actions в deny-list экспорта, assistant_requests (0064) из него не выпала — переиздано с последней редакции (Р16)');

select ok(
  pg_get_functiondef('public.bot_write_note(bigint,text,bigint)'::regprocedure) like '%unique_violation%',
  'bot_write_note держит гонку двух чатов на одной паре вложенным обработчиком (Р18а)');

select ok(
  not has_table_privilege('authenticated', 'public.bot_pending_actions', 'SELECT')
  and not has_table_privilege('anon', 'public.bot_pending_actions', 'SELECT')
  and not has_table_privilege('service_role', 'public.bot_pending_actions', 'SELECT')
  and not has_table_privilege('authenticated', 'public.bot_pending_actions', 'INSERT'),
  'bot_pending_actions закрыта грантами целиком');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'bot_pending_actions'), 0,
  'bot_pending_actions без политик — только RPC');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.bot_pending_actions'::regclass),
  'RLS на bot_pending_actions включён');

select ok(
  exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.bot_pending_actions'::regclass
           and tg.tgname = 'a00_readonly_guard' and not tg.tgisinternal),
  'bot_pending_actions под readonly guard (забор 0050; для бота no-op, read-only держит bot_assert_writable)');

select ok(
  not exists (select 1 from pg_trigger tg where tg.tgrelid = 'public.bot_pending_actions'::regclass
               and tg.tgname like '%audit%' and not tg.tgisinternal),
  'Аудита на bot_pending_actions нет — chat_id не попадает в audit_log (0042 В4)');

select is(
  (select array_agg(c.conname order by c.conname) from pg_constraint c
    where c.conrelid = 'public.bot_pending_actions'::regclass and c.contype = 'f'
      and not exists (
        select 1 from pg_index i
         join pg_class ic on ic.oid = i.indexrelid
         join pg_am am on am.oid = ic.relam
        where i.indrelid = c.conrelid
          and i.indpred is null and i.indisvalid and i.indislive and am.amname = 'btree'
          and (i.indkey::smallint[])[0:cardinality(c.conkey) - 1] @> c.conkey::smallint[]
      )),
  null,
  'Все четыре FK bot_pending_actions покрыты непартиальными btree-индексами (конвенция 0069)');

select is(
  (select count(*)::int from pg_constraint where conrelid = 'public.bot_pending_actions'::regclass and contype = 'f'), 4,
  'FK у bot_pending_actions ровно четыре — иначе забор выше прошёл бы вакуумно');

select ok(
  (select pg_get_functiondef('public.attendance_recalc_trigger()'::regprocedure) not like '%public.emit_event(%'
   and pg_get_functiondef('public.check_absent_streak(uuid,uuid,uuid)'::regprocedure) not like '%public.emit_event(%'
   and pg_get_functiondef('public.attendance_recalc_trigger()'::regprocedure) like '%emit_event_internal%'),
  'Триггеры посещения эмитят через emit_event_internal, не через emit_event с гейтом сессии (Р1)');


-- 2. Фикстура -------------------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
)
values
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000001','authenticated','authenticated','owner-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000002','authenticated','authenticated','teacher-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000003','authenticated','authenticated','other-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000004','authenticated','authenticated','parent-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000005','authenticated','authenticated','registrar-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000006','authenticated','authenticated','owner-x-0071@test.kg','','','','','','','',''),
  ('00000000-0000-0000-0000-000000000000','70700000-0000-0000-0000-000000000007','authenticated','authenticated','owner-d-0071@test.kg','','','','','','','','');

create temporary table t_tz as
  select (select name from pg_timezone_names
           where name like 'Etc/GMT%'
             and extract(hour from (now() at time zone name))::int between 9 and 19
           order by name limit 1) as tz_day;

-- c1 — живой; c2 — trial истёк; c3 — помечен на удаление (ниже).
insert into public.centers (id, name, slug, trial_ends_at, settings) values
  ('70700000-0000-0000-0000-0000000000c1','Центр 0071',  'centr-0071',   now() + interval '7 days', jsonb_build_object('timezone', (select tz_day from t_tz))),
  ('70700000-0000-0000-0000-0000000000c2','Центр 0071 X','centr-0071-x', now() - interval '2 days', jsonb_build_object('timezone', (select tz_day from t_tz))),
  ('70700000-0000-0000-0000-0000000000c3','Центр 0071 D','centr-0071-d', now() + interval '7 days', jsonb_build_object('timezone', (select tz_day from t_tz)));

insert into public.teachers (id, center_id, full_name) values
  ('70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-0000000000c1','Ведущий 0071'),
  ('70700000-0000-0000-0000-00000000aa02','70700000-0000-0000-0000-0000000000c1','Другой 0071'),
  ('70700000-0000-0000-0000-00000000aa03','70700000-0000-0000-0000-0000000000c2','Спец X 0071'),
  ('70700000-0000-0000-0000-00000000aa04','70700000-0000-0000-0000-0000000000c3','Спец D 0071');

insert into public.services (id, center_id, name, default_price_tiyin) values
  ('70700000-0000-0000-0000-00000000bb01','70700000-0000-0000-0000-0000000000c1','Логопед 0071',70000),
  ('70700000-0000-0000-0000-00000000bb02','70700000-0000-0000-0000-0000000000c2','Логопед X',70000),
  ('70700000-0000-0000-0000-00000000bb03','70700000-0000-0000-0000-0000000000c3','Логопед D',70000);

insert into public.payers (id, center_id, full_name, phone) values
  ('70700000-0000-0000-0000-00000000dd01','70700000-0000-0000-0000-0000000000c1','Родитель 0071','+996700007170'),
  ('70700000-0000-0000-0000-00000000dd02','70700000-0000-0000-0000-0000000000c2','Родитель X','+996700007171'),
  ('70700000-0000-0000-0000-00000000dd03','70700000-0000-0000-0000-0000000000c3','Родитель D','+996700007172');

insert into public.memberships (user_id, center_id, role, teacher_id, payer_id) values
  ('70700000-0000-0000-0000-000000000001','70700000-0000-0000-0000-0000000000c1','owner',     null, null),
  ('70700000-0000-0000-0000-000000000002','70700000-0000-0000-0000-0000000000c1','teacher',   '70700000-0000-0000-0000-00000000aa01', null),
  ('70700000-0000-0000-0000-000000000003','70700000-0000-0000-0000-0000000000c1','teacher',   '70700000-0000-0000-0000-00000000aa02', null),
  ('70700000-0000-0000-0000-000000000004','70700000-0000-0000-0000-0000000000c1','parent',    null, '70700000-0000-0000-0000-00000000dd01'),
  ('70700000-0000-0000-0000-000000000005','70700000-0000-0000-0000-0000000000c1','registrar', null, null),
  ('70700000-0000-0000-0000-000000000006','70700000-0000-0000-0000-0000000000c2','owner',     null, null),
  ('70700000-0000-0000-0000-000000000007','70700000-0000-0000-0000-0000000000c3','owner',     null, null);

insert into public.students (id, center_id, full_name, payer_id) values
  ('70700000-0000-0000-0000-00000000ee01','70700000-0000-0000-0000-0000000000c1','Айсулуу 0071','70700000-0000-0000-0000-00000000dd01'),
  ('70700000-0000-0000-0000-00000000ee02','70700000-0000-0000-0000-0000000000c1','Бекжан 0071', '70700000-0000-0000-0000-00000000dd01'),
  ('70700000-0000-0000-0000-00000000ee03','70700000-0000-0000-0000-0000000000c1','Ислам 0071',  '70700000-0000-0000-0000-00000000dd01'),
  ('70700000-0000-0000-0000-00000000ee05','70700000-0000-0000-0000-0000000000c1','Архивный 0071','70700000-0000-0000-0000-00000000dd01'),
  ('70700000-0000-0000-0000-00000000ee04','70700000-0000-0000-0000-0000000000c2','Ребёнок X',   '70700000-0000-0000-0000-00000000dd02'),
  ('70700000-0000-0000-0000-00000000ee06','70700000-0000-0000-0000-0000000000c3','Ребёнок D',   '70700000-0000-0000-0000-00000000dd03');

-- Абонемент Айсулуу на 3 занятия: первое списание оставляет 2 → low_balance.
insert into public.subscriptions (id, center_id, student_id, payer_id, lessons_total, price_tiyin, lesson_price_tiyin, starts_at) values
  ('70700000-0000-0000-0000-000000005501','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000ee01',
   '70700000-0000-0000-0000-00000000dd01', 3, 210000, 70000, current_date - 7);

insert into public.groups (id, center_id, name) values
  ('70700000-0000-0000-0000-000000009901','70700000-0000-0000-0000-0000000000c1','Группа 0071');

-- joined_at явно (0041): starts_at от now() с отрицательным интервалом.
insert into public.group_students (group_id, student_id, center_id, joined_at) values
  ('70700000-0000-0000-0000-000000009901','70700000-0000-0000-0000-00000000ee01','70700000-0000-0000-0000-0000000000c1', current_date - 7),
  ('70700000-0000-0000-0000-000000009901','70700000-0000-0000-0000-00000000ee02','70700000-0000-0000-0000-0000000000c1', current_date - 7),
  ('70700000-0000-0000-0000-000000009901','70700000-0000-0000-0000-00000000ee05','70700000-0000-0000-0000-0000000000c1', current_date - 7);

-- ff01 — индивидуальное, началось; ff02 — групповое, началось; ff03 — ещё
-- не началось; ff04 — вчера; ff05 — истёкший центр; ff06 — удалённый центр.
insert into public.lessons (id, center_id, teacher_id, service_id, student_id, group_id, status, starts_at, ends_at) values
  ('70700000-0000-0000-0000-00000000ff01','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-00000000bb01','70700000-0000-0000-0000-00000000ee03',null,'planned', now() - interval '1 hour', now() - interval '15 minutes'),
  ('70700000-0000-0000-0000-00000000ff02','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-00000000bb01',null,'70700000-0000-0000-0000-000000009901','planned', now() - interval '3 hours', now() - interval '2 hours'),
  ('70700000-0000-0000-0000-00000000ff03','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-00000000bb01','70700000-0000-0000-0000-00000000ee03',null,'planned', now() + interval '2 hours', now() + interval '3 hours'),
  ('70700000-0000-0000-0000-00000000ff04','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-00000000bb01','70700000-0000-0000-0000-00000000ee03',null,'planned', now() - interval '1 day', now() - interval '1 day' + interval '45 minutes'),
  ('70700000-0000-0000-0000-00000000ff05','70700000-0000-0000-0000-0000000000c2','70700000-0000-0000-0000-00000000aa03','70700000-0000-0000-0000-00000000bb02','70700000-0000-0000-0000-00000000ee04',null,'planned', now() - interval '1 hour', now() - interval '15 minutes'),
  ('70700000-0000-0000-0000-00000000ff06','70700000-0000-0000-0000-0000000000c3','70700000-0000-0000-0000-00000000aa04','70700000-0000-0000-0000-00000000bb03','70700000-0000-0000-0000-00000000ee06',null,'planned', now() - interval '1 hour', now() - interval '15 minutes'),
  -- ff07 — индивидуальное Бекжана без отметки, для закрытого месяца (раздел 9);
  -- окно между ff02 и ff01 того же специалиста — иначе EXCLUDE 0006.
  ('70700000-0000-0000-0000-00000000ff07','70700000-0000-0000-0000-0000000000c1','70700000-0000-0000-0000-00000000aa01','70700000-0000-0000-0000-00000000bb01','70700000-0000-0000-0000-00000000ee02',null,'planned', now() - interval '110 minutes', now() - interval '80 minutes');

-- Архивный ребёнок — после сборки состава занятия (Р10).
update public.students set deleted_at = now() where id = '70700000-0000-0000-0000-00000000ee05';
-- Центр c3 помечен на удаление (0056: deleted_at, protect_plan его не судит).
update public.centers set deleted_at = now() where id = '70700000-0000-0000-0000-0000000000c3';

insert into public.telegram_accounts (user_id, chat_id) values
  ('70700000-0000-0000-0000-000000000001', 707001),
  ('70700000-0000-0000-0000-000000000002', 707002),
  ('70700000-0000-0000-0000-000000000003', 707003),
  ('70700000-0000-0000-0000-000000000004', 707004),
  ('70700000-0000-0000-0000-000000000005', 707005),
  ('70700000-0000-0000-0000-000000000006', 707006),
  ('70700000-0000-0000-0000-000000000007', 707007);

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', json_build_object('center_id', p_center))::text, true);
end;
$$;

create temporary table t_st as
  select code, id from public.attendance_statuses where center_id = '70700000-0000-0000-0000-0000000000c1';


-- 3. Безсессионный путь: триггер посещения не требует auth.uid() (Р1) -----------------------------

select lives_ok(
  $q$ insert into public.attendance (center_id, lesson_id, student_id, status_id)
      values ('70700000-0000-0000-0000-0000000000c1', '70700000-0000-0000-0000-00000000ff02',
              '70700000-0000-0000-0000-00000000ee02', (select id from t_st where code = 'present')) $q$,
  'Прямой insert в attendance без сессии проходит — attendance_recalc_trigger больше не падает на emit_event');

select is(
  (select count(*)::int from public.events
    where type = 'attendance.marked' and payload ->> 'student_id' = '70700000-0000-0000-0000-00000000ee02'), 1,
  'И даёт attendance.marked через emit_event_internal');


-- 4. bot_today: кнопки по ролям, время в поясе центра (Р13) ---------------------------------------

select is(
  (select count(*)::int from public.bot_today(707002)), 4,
  'Специалист видит четыре сегодняшних занятия (вчерашнее — нет)');

select is(
  (select starts_local from public.bot_today(707002) where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  (select to_char(l.starts_at at time zone public.center_timezone(l.center_id), 'HH24:MI')
     from public.lessons l where l.id = '70700000-0000-0000-0000-00000000ff01'),
  'starts_local — в поясе центра, а не сервера');

select is(
  (select array[can_mark, can_note] from public.bot_today(707002) where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  array[true, true],
  'Ведущий специалист: началось — can_mark и can_note');

select is(
  (select array[can_mark, can_note] from public.bot_today(707002) where lesson_id = '70700000-0000-0000-0000-00000000ff03'),
  array[false, true],
  'Не началось — can_mark false, заметка доступна');

select ok(
  (select bool_and(not can_mark and not can_note) from public.bot_today(707004)),
  'Родителю кнопок нет вовсе');

select is(
  (select array[can_mark, can_note] from public.bot_today(707005) where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  array[true, false],
  'Регистратор: посещение — да, заметка — нет (как write_lesson_note)');

select is(
  (select count(*)::int from public.bot_today(707003)), 0,
  'Другой специалист центра занятий ведущего не видит (0033 Р4)');


-- 5. Посещение: индивидуальное занятие --------------------------------------------------------------

select throws_ok(
  $q$ select public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) $q$,
  '42704', null, 'Без контекста — 42704, не голая ошибка');

select is(
  (select r ->> 'student_id' from public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff01') r),
  '70700000-0000-0000-0000-00000000ee03',
  'Один участник — ребёнок выбран сразу');

select is(
  (select count(*)::int from public.bot_pending_actions where chat_id = 707002 and consumed_at is null), 1,
  'Один живой контекст на чат');

select is(
  (select jsonb_array_length(r -> 'statuses') from public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff01') r), 4,
  'Статусы центра для кнопок — четыре из сида 0008; повторное армирование не даёт 23505');

select is(
  (select count(*)::int from public.bot_pending_actions where chat_id = 707002 and consumed_at is null), 1,
  'Повторное армирование гасит предыдущее, живой снова один');

select is(
  public.bot_mark_attendance(707002, (select id from t_st where code = 'present')),
  '{"changed": true, "status_name": "Пришёл", "student_name": "Ислам 0071"}'::jsonb,
  'Отметка из бота проходит (блокер Р1 закрыт)');

select is(
  (select marked_by from public.attendance
    where lesson_id = '70700000-0000-0000-0000-00000000ff01' and student_id = '70700000-0000-0000-0000-00000000ee03'),
  '70700000-0000-0000-0000-000000000002'::uuid,
  'marked_by — пользователь чата, триггер его не затёр');

select set_eq(
  $$ select type from public.events where payload ->> 'student_id' = '70700000-0000-0000-0000-00000000ee03' $$,
  $$ values ('attendance.marked'), ('attendance.no_subscription') $$,
  'События как с экрана: marked + no_subscription (абонемента нет, статус списывающий) — Р2');

select is(
  (select count(*)::int from public.bot_pending_actions where chat_id = 707002 and consumed_at is null), 0,
  'Контекст погашен после записи');

select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff01');
select is(
  (select r ->> 'changed' from public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) r),
  'false',
  'Тот же статус повторно — идемпотентный успех, changed=false');

select is(
  (select count(*)::int from public.events where payload ->> 'student_id' = '70700000-0000-0000-0000-00000000ee03'), 2,
  'Повтор не добавил событий (дедупликация 0010 + отсутствие UPDATE)');

select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff01');
select throws_ok(
  $q$ select public.bot_mark_attendance(707002, (select id from t_st where code = 'sick')) $q$,
  '22023', 'Отметка уже стоит — изменить её можно на экране занятия',
  'Другой статус — отказ, бот отметку не переписывает (Р6)');

select is(
  (select status_id from public.attendance
    where lesson_id = '70700000-0000-0000-0000-00000000ff01' and student_id = '70700000-0000-0000-0000-00000000ee03'),
  (select id from t_st where code = 'present'),
  'Статус остался прежним');

select throws_ok(
  $q$ select public.bot_mark_attendance(707002, '70700000-0000-0000-0000-000000000000') $q$,
  '42704', 'Статус посещения не найден',
  'Статус не из этого центра / несуществующий — 42704');

update public.bot_pending_actions set expires_at = now() - interval '1 second'
 where chat_id = 707002 and consumed_at is null;
select throws_ok(
  $q$ select public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) $q$,
  '42704', null, 'Протухший контекст — как отсутствующий');


-- 6. Посещение: групповое занятие, выбор ребёнка, абонемент ---------------------------------------

select is(
  (select r ->> 'student_id' from public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff02') r),
  null,
  'Групповое — ребёнок не выбран');

select is(
  (select jsonb_array_length(r -> 'students') from public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff02') r), 2,
  'Участников двое — архивный из списка исключён (Р10)');

select throws_ok(
  $q$ select public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) $q$,
  '22023', 'Сначала выберите ребёнка', 'Отметить до выбора ребёнка нельзя');

select throws_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee03') $q$,
  '22023', 'Этот ребёнок не участник занятия', 'Ребёнок не из этого занятия — отказ (Р15)');

select throws_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee05') $q$,
  '22023', 'Этот ребёнок не участник занятия', 'Архивный участник — отказ (Р10)');

select is(
  (select r ->> 'student_name' from public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee01') r),
  'Айсулуу 0071',
  'Выбор участника проходит');

select is(
  (select r ->> 'changed' from public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) r),
  'true',
  'Отметка на групповом занятии проходит');

select set_eq(
  $$ select type from public.events where payload ->> 'student_id' = '70700000-0000-0000-0000-00000000ee01' $$,
  $$ values ('attendance.marked'), ('subscription.low_balance') $$,
  'С абонементом на 3: списание оставило 2 → low_balance ушёл, как с экрана (Р2)');

select is(
  (select lessons_used from public.subscriptions where id = '70700000-0000-0000-0000-000000005501'), 1,
  'Списание с абонемента прошло из контура бота');


-- 7. Права, окна, read-only -----------------------------------------------------------------------

select throws_ok(
  $q$ select public.bot_arm_action(707004, 'attendance', '70700000-0000-0000-0000-00000000ff01') $q$,
  '42501', null, 'Родитель — 42501');

select throws_ok(
  $q$ select public.bot_arm_action(707003, 'attendance', '70700000-0000-0000-0000-00000000ff01') $q$,
  '42501', null, 'Другой специалист центра — 42501 (Р9)');

select throws_ok(
  $q$ select public.bot_arm_action(707005, 'note', '70700000-0000-0000-0000-00000000ff01') $q$,
  '42501', null, 'Регистратор — заметку не пишет (Р9)');

select lives_ok(
  $q$ select public.bot_arm_action(707005, 'attendance', '70700000-0000-0000-0000-00000000ff01') $q$,
  'Регистратор — посещение отмечает, как с экрана');

select throws_ok(
  $q$ select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff03') $q$,
  '22023', 'Занятие ещё не началось', 'Не началось — 22023');

select throws_ok(
  $q$ select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff04') $q$,
  '22023', null, 'Вчерашнее — только за сегодня (Р8)');

select throws_ok(
  $q$ select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-000000000000') $q$,
  '42704', null, 'Несуществующее занятие — 42704');

select throws_ok(
  $q$ select public.bot_arm_action(707002, 'homework', '70700000-0000-0000-0000-00000000ff01') $q$,
  '22023', null, 'Неизвестный вид действия — 22023');

select throws_ok(
  $q$ select public.bot_arm_action(999999, 'attendance', '70700000-0000-0000-0000-00000000ff01') $q$,
  '42501', null, 'Непривязанный чат — 42501');

select throws_ok(
  $q$ select public.bot_arm_action(707006, 'attendance', '70700000-0000-0000-0000-00000000ff05') $q$,
  'PT402', 'Подписка центра истекла — доступно только чтение. Оплатите тариф в настройках центра',
  'Истёкший trial: PT402 с текстом для owner (Р11)');

select throws_ok(
  $q$ select public.bot_arm_action(707007, 'attendance', '70700000-0000-0000-0000-00000000ff06') $q$,
  'PT402', 'Центр помечен на удаление — доступны выгрузка данных и отмена в настройках тарифа',
  'Центр на удалении: другой текст, не «истекла подписка» (0056 Р7)');

-- Права перепроверяются между шагами (Р9): отзыв членства после arm.
select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff02');
create temporary table t_m as select * from public.memberships where user_id = '70700000-0000-0000-0000-000000000002';
delete from public.memberships where user_id = '70700000-0000-0000-0000-000000000002';
select throws_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee02') $q$,
  '42501', null, 'Членство отозвано после arm — pick отказывает');
insert into public.memberships select * from t_m;


-- 8. Заметка --------------------------------------------------------------------------------------

select throws_ok(
  $q$ select public.bot_write_note(707002, 'текст') $q$,
  '42704', null, 'Без контекста заметки — 42704');

select is(
  (select r ->> 'student_name' from public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff01') r),
  'Ислам 0071',
  'Заметка: один участник — выбран сразу');

select ok(
  (select expires_at - created_at <= interval '3 minutes'
     from public.bot_pending_actions where chat_id = 707002 and consumed_at is null),
  'Окно заметки — 3 минуты, не 15 (Р14)');

select throws_ok(
  $q$ select public.bot_write_note(707002, '   ') $q$,
  '22023', 'Пустая заметка', 'Пробелы — пусто');

select throws_ok(
  $q$ select public.bot_write_note(707002, repeat('я', 2001)) $q$,
  '22023', null, '2001 знак — 22023');

select is(
  public.bot_write_note(707002, '  Работали над звуком Р  '),
  '{"preview": "Работали над звуком Р", "appended": false, "student_name": "Ислам 0071"}'::jsonb,
  'Заметка записана, текст обрезан по краям');

select is(
  (select row(created_by, center_id, teacher_id, source::text, status::text, soap)
     from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  row('70700000-0000-0000-0000-000000000002'::uuid, '70700000-0000-0000-0000-0000000000c1'::uuid,
      '70700000-0000-0000-0000-00000000aa01'::uuid, 'text'::text, 'draft'::text, '{"objective": "Работали над звуком Р"}'::jsonb),
  'created_by — пользователь чата, center_id явно, teacher_id — карточка специалиста, черновик в soap.objective (Р3/Р12)');

select public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff01');
select is(
  (select r ->> 'appended' from public.bot_write_note(707002, 'Домашка выдана') r), 'true',
  'Второй текст дописан');

select is(
  (select soap ->> 'objective' from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  E'Работали над звуком Р\nДомашка выдана',
  'Дописано через перевод строки, первая версия не потеряна');

-- Р3: автор утверждает свою заметку с экрана. Резюме для родителя — только
-- руками на экране (0047 Р3: без parent_summary утверждать нечего); бот его
-- не пишет, здесь оно подставляется напрямую, чтобы проверить именно право
-- автора, а не форму.
update public.lesson_notes set parent_summary = 'Резюме для родителя'
 where lesson_id = '70700000-0000-0000-0000-00000000ff01';
select public.tests_claims('70700000-0000-0000-0000-000000000002', '70700000-0000-0000-0000-0000000000c1');
set local role authenticated;
select lives_ok(
  $q$ select public.approve_lesson_note((select id from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff01')) $q$,
  'Автор утверждает заметку из бота с экрана — created_by проставлен (0041 Р2)');
reset role;
select public.tests_claims(null, null);

select is(
  (select approved_by from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff01'),
  '70700000-0000-0000-0000-000000000002'::uuid,
  'Утвердил именно автор');

select public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff01');
select throws_ok(
  $q$ select public.bot_write_note(707002, 'ещё') $q$,
  '23514', null, 'Утверждённую заметку из бота не дописать');

-- Р12: живая диктовка по паре — печатный текст отказывается.
insert into public.lesson_voice_requests (token, center_id, lesson_id, student_id, teacher_id, requested_by, chat_id, expires_at, armed_at)
values ('tok-0071', '70700000-0000-0000-0000-0000000000c1', '70700000-0000-0000-0000-00000000ff02',
        '70700000-0000-0000-0000-00000000ee02', '70700000-0000-0000-0000-00000000aa01',
        '70700000-0000-0000-0000-000000000002', 707002, now() + interval '10 minutes', now());
select public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff02');
select throws_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee02') $q$,
  '22023', null, 'Ждём голосовое по этому ребёнку — печатная заметка отклонена (Р12)');
select lives_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee01') $q$,
  'По другому ребёнку той же группы диктовки нет — выбор проходит');
select lives_ok(
  $q$ select public.bot_write_note(707002, 'Айсулуу: ритм') $q$,
  'Заметка на групповом занятии пишется выбранному ребёнку');
select is(
  (select student_id from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff02'),
  '70700000-0000-0000-0000-00000000ee01'::uuid,
  'Именно ей, не соседу по группе');


-- 8б. Межцентровая изоляция, чужой черновик, owner, диктовка в обработке, два чата, ForceReply ----

select throws_ok(
  $q$ select public.bot_arm_action(707006, 'attendance', '70700000-0000-0000-0000-00000000ff01') $q$,
  '42704', 'Занятие не найдено', 'Owner другого центра — занятие «не найдено», не 42501 (нет оракула существования)');

select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff02');
select throws_ok(
  $q$ select public.bot_pick_student(707002, '70700000-0000-0000-0000-00000000ee04') $q$,
  '22023', 'Этот ребёнок не участник занятия', 'Ребёнок чужого центра на групповом — отказ (Р15)');

-- Два чата — два живых контекста: unique частичный по chat_id, не глобальный.
select public.bot_arm_action(707005, 'attendance', '70700000-0000-0000-0000-00000000ff01');
select is(
  (select count(*)::int from public.bot_pending_actions where consumed_at is null and chat_id in (707002, 707005)), 2,
  'Два чата ведут свои шаги одновременно');

-- Р18б: чужой черновик (Айсулуу на ff02 начал специалист) owner из бота не дописывает.
select public.bot_arm_action(707001, 'note', '70700000-0000-0000-0000-00000000ff02');
select public.bot_pick_student(707001, '70700000-0000-0000-0000-00000000ee01');
select throws_ok(
  $q$ select public.bot_write_note(707001, 'дописка owner') $q$,
  '22023', null, 'Чужой черновик из бота не дописывается (Р18б)');
select is(
  (select soap ->> 'objective' from public.lesson_notes
    where lesson_id = '70700000-0000-0000-0000-00000000ff02' and student_id = '70700000-0000-0000-0000-00000000ee01'),
  'Айсулуу: ритм',
  'Текст специалиста не тронут');

-- Owner пишет свою заметку: teacher_id пуст, created_by — owner, утверждает сам.
select public.bot_arm_action(707001, 'note', '70700000-0000-0000-0000-00000000ff03');
select lives_ok(
  $q$ select public.bot_write_note(707001, 'Заметка владельца') $q$,
  'Owner пишет заметку на сегодняшнее занятие, которое ещё не началось (Р13: заметка без «началось»)');
select is(
  (select row(teacher_id, created_by) from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff03'),
  row(null::uuid, '70700000-0000-0000-0000-000000000001'::uuid),
  'У заметки owner нет карточки специалиста, автор — owner');

-- Р17: диктовка в обработке (файл принят, заметки ещё нет) — печатный текст отклоняется.
insert into public.lesson_voice_requests (id, token, center_id, lesson_id, student_id, teacher_id, requested_by, chat_id, expires_at, armed_at, consumed_at)
values ('70700000-0000-0000-0000-00000000aa71', 'tok-0071-b', '70700000-0000-0000-0000-0000000000c1', '70700000-0000-0000-0000-00000000ff07',
        '70700000-0000-0000-0000-00000000ee02', '70700000-0000-0000-0000-00000000aa01',
        '70700000-0000-0000-0000-000000000002', 707002, now() - interval '1 minute', now() - interval '2 minutes', now() - interval '1 minute');
select throws_ok(
  $q$ select public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff07') $q$,
  '22023', null, 'Файл принят, разбор ИИ ещё идёт — заметка текстом отклонена (Р17)');

-- Разбор провалился — окно закрыто, текст снова принимается.
insert into public.events (id, center_id, type, payload) values
  (907071, '70700000-0000-0000-0000-0000000000c1', 'lesson.voice_received',
   jsonb_build_object('center_id', '70700000-0000-0000-0000-0000000000c1', 'voice_request_id', '70700000-0000-0000-0000-00000000aa71'));
insert into public.ai_jobs (event_id, center_id, status, finished_at) values (907071, '70700000-0000-0000-0000-0000000000c1', 'failed', now());
select lives_ok(
  $q$ select public.bot_arm_action(707002, 'note', '70700000-0000-0000-0000-00000000ff07') $q$,
  'Провал работы ИИ закрывает окно диктовки — заметку можно набрать');

-- Р18в: корреляция ForceReply.
select throws_ok(
  $q$ select public.bot_bind_prompt(707005, 123) $q$,
  '42704', null, 'Привязать промпт без живой заметки нельзя (у 707005 контекст посещения)');
select lives_ok(
  $q$ select public.bot_bind_prompt(707002, 555) $q$,
  'Промпт привязан к живой заметке');
select throws_ok(
  $q$ select public.bot_write_note(707002, 'ответ не туда', 556) $q$,
  '22023', null, 'Ответ на другой промпт — отказ, текст не ложится в карту (Р18в)');
select is(
  (select count(*)::int from public.lesson_notes where lesson_id = '70700000-0000-0000-0000-00000000ff07'), 0,
  'Заметки нет');
select lives_ok(
  $q$ select public.bot_write_note(707002, 'ответ на свой промпт', 555) $q$,
  'Ответ на свой промпт принимается');


-- 9. Закрытый месяц — забор finance работает и в контуре бота ---------------------------------------

insert into public.financial_periods (center_id, month, closed_at)
values ('70700000-0000-0000-0000-0000000000c1',
        date_trunc('month', public.center_today('70700000-0000-0000-0000-0000000000c1'))::date, now());
select public.bot_arm_action(707002, 'attendance', '70700000-0000-0000-0000-00000000ff07');
select throws_ok(
  $q$ select public.bot_mark_attendance(707002, (select id from t_st where code = 'present')) $q$,
  '22023', null, 'Закрытый месяц — отказ и из бота (financial_period_guard без сессии)');
select is(
  (select count(*)::int from public.attendance where lesson_id = '70700000-0000-0000-0000-00000000ff07'), 0,
  'Отметки нет — отказ пришёл из guard, а не из «уже стоит»');


select * from finish();
rollback;
