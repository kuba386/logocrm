-- pgTAP: архив attendance_statuses и subscription_types (миграция 0012).
-- Инвариант «один default на центр» теперь держит отложенный constraint
-- trigger без self-referential update — проверяем итоговое состояние на
-- коммите транзакции, а не промежуточные шаги set_default_attendance_status.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(33);

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
  ('00000000-0000-0000-0000-000000000000','66666666-6666-6666-6666-666666666666','authenticated','authenticated','revoked@test.kg','','','','','','','','');

insert into public.centers (id, name, slug, settings) values
  ('cccccccc-0000-0000-0000-00000000000a','Центр А','centr-a','{"timezone":"Asia/Bishkek"}'::jsonb),
  ('cccccccc-0000-0000-0000-00000000000b','Центр Б','centr-b','{"timezone":"Asia/Bishkek"}'::jsonb);

insert into public.teachers (id, center_id, full_name) values
  ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Препод А');

insert into public.payers (id, center_id, full_name, phone) values
  ('bbbbbbbb-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Иванова А.','+996700111222');

insert into public.students (id, center_id, full_name, payer_id, primary_teacher_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Данияр','bbbbbbbb-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001');

insert into public.services (id, center_id, name, duration_min, default_price_tiyin)
values ('99999999-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Индивидуальное',45,50000);

insert into public.lessons (id, center_id, service_id, teacher_id, student_id, starts_at, ends_at)
values ('44444444-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a',
        '99999999-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001',
        'eeeeeeee-0000-0000-0000-000000000001', now() - interval '1 day', now() - interval '1 day' + interval '45 min');

insert into public.subscription_types (id, center_id, name, kind, lessons_count, price_tiyin) values
  ('77777777-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-00000000000a','Восемь занятий','lessons',8,400000),
  ('77777777-0000-0000-0000-00000000000b','cccccccc-0000-0000-0000-00000000000b','Чужой тип','lessons',8,100000);

insert into public.memberships (user_id, center_id, role, teacher_id) values
  ('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a','owner',null),
  ('22222222-2222-2222-2222-222222222222','cccccccc-0000-0000-0000-00000000000b','owner',null),
  ('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a','teacher','aaaaaaaa-0000-0000-0000-000000000001');

create or replace function public.tests_claims(p_user uuid, p_center uuid)
  returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated',
      'app_metadata', case when p_center is null then '{}'::json
                           else json_build_object('center_id', p_center) end)::text, true);
end;
$$;

-- centers_seed_attendance_statuses уже засеял по 4 статуса каждому центру
-- (present=default, late, sick, absent) — берём их id в темповую таблицу,
-- как t_sub в 0008_subscriptions.test.sql, а не хардкодим gen_random_uuid().
create temporary table t_status (name text primary key, id uuid);
grant select, insert on t_status to authenticated;

insert into t_status (name, id)
select 'a_present', id from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'present';
insert into t_status (name, id)
select 'a_late', id from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'late';
insert into t_status (name, id)
select 'a_sick', id from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'sick';
insert into t_status (name, id)
select 'a_absent', id from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000a' and code = 'absent';
insert into t_status (name, id)
select 'b_present', id from public.attendance_statuses
 where center_id = 'cccccccc-0000-0000-0000-00000000000b' and code = 'present';


-- 1-5. Отозванное членство: все пять RPC отвечают 42501 первой строкой -----------

select public.tests_claims('66666666-6666-6666-6666-666666666666','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'a_late')) $q$,
  '42501', 'Недостаточно прав', 'archive_attendance_status: отозванный получает 42501'
);
select throws_ok(
  $q$ select public.restore_attendance_status((select id from t_status where name = 'a_late')) $q$,
  '42501', 'Недостаточно прав', 'restore_attendance_status: 42501'
);
select throws_ok(
  $q$ select public.set_default_attendance_status((select id from t_status where name = 'a_sick')) $q$,
  '42501', 'Недостаточно прав', 'set_default_attendance_status: 42501'
);
select throws_ok(
  $q$ select public.archive_subscription_type('77777777-0000-0000-0000-000000000001') $q$,
  '42501', 'Недостаточно прав', 'archive_subscription_type: 42501'
);
select throws_ok(
  $q$ select public.restore_subscription_type('77777777-0000-0000-0000-000000000001') $q$,
  '42501', 'Недостаточно прав', 'restore_subscription_type: 42501'
);

reset role;


-- 6-8. Колоночные гранты: deleted_at/is_default закрыты даже владельцу напрямую ---

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ update public.attendance_statuses set deleted_at = now()
       where id = (select id from t_status where name = 'a_late') $q$,
  '42501', null, 'Прямой PATCH deleted_at на attendance_statuses отклонён — только через RPC'
);
select throws_ok(
  $q$ update public.attendance_statuses set is_default = true
       where id = (select id from t_status where name = 'a_sick') $q$,
  '42501', null, 'Прямой PATCH is_default отклонён — только через set_default_attendance_status'
);
select throws_ok(
  $q$ update public.subscription_types set deleted_at = now()
       where id = '77777777-0000-0000-0000-000000000001' $q$,
  '42501', null, 'Прямой PATCH deleted_at на subscription_types отклонён'
);


-- 9. Архив действующего default — синхронный CHECK, не отложенный триггер -------

-- deleted_at меняется на строке, где is_default ещё true —
-- attendance_statuses_default_not_deleted ловит это в момент UPDATE, до
-- commit и до отложенного триггера (тот проверяет только «нулевой default»,
-- см. тест в конце файла).
select throws_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'a_present')) $q$,
  '23514', null,
  'Архив статуса по умолчанию отклонён CHECK-констрейнтом синхронно'
);


-- 10-11. Архив обычного статуса проходит ------------------------------------------

select lives_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'a_late')) $q$,
  'Архив не-default статуса проходит'
);
select isnt(
  (select deleted_at from public.attendance_statuses where id = (select id from t_status where name = 'a_late')),
  null,
  'a_late помечен deleted_at'
);


-- 12. Межтенантная граница: чужой центр не найден, не 42501 ----------------------

select throws_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'b_present')) $q$,
  '42704', 'Статус не найден', 'Архив статуса чужого центра — 42704, не тихий успех'
);


-- 13. INSERT-обход: одновременный default+deleted_at держит CHECK, не триггер ----

select throws_ok(
  $q$ insert into public.attendance_statuses (center_id, code, name, is_default, deleted_at)
      values ('cccccccc-0000-0000-0000-00000000000a','z','Z', true, now()) $q$,
  '23514', null, 'INSERT с is_default и deleted_at разом отклонён CHECK-констрейнтом'
);


-- 14-16. set_default_attendance_status переносит флаг одной транзакцией ----------

select lives_ok(
  $q$ select public.set_default_attendance_status((select id from t_status where name = 'a_sick')) $q$,
  'Назначение нового default проходит'
);
select is(
  (select count(*)::int from public.attendance_statuses
    where center_id = 'cccccccc-0000-0000-0000-00000000000a' and is_default and deleted_at is null),
  1,
  'После переноса default в центре по-прежнему ровно один живой default'
);
select throws_ok(
  $q$ select public.set_default_attendance_status(gen_random_uuid()) $q$,
  '42704', 'Статус не найден', 'set_default_attendance_status на несуществующий id — 42704'
);


-- 17. Восстановление возвращает статус в общий список -----------------------------

select lives_ok(
  $q$ select public.restore_attendance_status((select id from t_status where name = 'a_late')) $q$,
  'Восстановление a_late проходит'
);
select is(
  (select deleted_at from public.attendance_statuses where id = (select id from t_status where name = 'a_late')),
  null,
  'a_late снова живой'
);


-- 18. Коллизия кода при восстановлении — дружелюбный текст, не голый 23505 --------

select lives_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'a_late')) $q$,
  'a_late архивирован повторно для проверки коллизии кода'
);
select lives_ok(
  $q$ insert into public.attendance_statuses (center_id, code, name)
      values ('cccccccc-0000-0000-0000-00000000000a','late','Опоздал (новый)') $q$,
  'Новый живой статус с тем же кодом «late» создан, пока архивный существует'
);
select throws_ok(
  $q$ select public.restore_attendance_status((select id from t_status where name = 'a_late')) $q$,
  '22023', 'Код «late» уже занят другим статусом — переименуйте перед восстановлением',
  'Восстановление при занятом коде — читаемый 22023, не нативный unique_violation'
);


-- 19. mark_attendance после архива: архивный код недоступен, остальное работает --

select lives_ok(
  $q$ select public.archive_attendance_status((select id from t_status where name = 'a_absent')) $q$,
  'a_absent архивирован для проверки mark_attendance'
);

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select lives_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000001',
                                    'eeeeeeee-0000-0000-0000-000000000001', null) $q$,
  'mark_attendance без кода по-прежнему ставит текущий default (a_sick)'
);
select throws_ok(
  $q$ select public.mark_attendance('44444444-0000-0000-0000-000000000001',
                                    'eeeeeeee-0000-0000-0000-000000000001', 'absent') $q$,
  '42704', 'Статус посещения не найден', 'mark_attendance архивным кодом отклонён'
);

reset role;


-- 20-21. attendance_statuses_read_all: специалист видит архивные строки ----------

select public.tests_claims('33333333-3333-3333-3333-333333333333','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select is(
  (select count(*)::int from public.attendance_statuses
    where id = (select id from t_status where name = 'a_absent')),
  1,
  'Специалист видит архивный статус — история посещений не теряет имя и цвет'
);

reset role;


-- 22. subscription_types: межтенантная граница, архив, видимость, восстановление -

select public.tests_claims('11111111-1111-1111-1111-111111111111','cccccccc-0000-0000-0000-00000000000a');
set local role authenticated;

select throws_ok(
  $q$ select public.archive_subscription_type('77777777-0000-0000-0000-00000000000b') $q$,
  '42704', 'Тип абонемента не найден', 'Архив типа чужого центра — 42704'
);
select lives_ok(
  $q$ select public.archive_subscription_type('77777777-0000-0000-0000-000000000001') $q$,
  'Владелец архивирует свой тип абонемента'
);
select is(
  (select count(*)::int from public.subscription_types
    where id = '77777777-0000-0000-0000-000000000001' and deleted_at is not null),
  1,
  'Владелец видит собственный архивный тип через subscription_types_read_archived'
);
select throws_ok(
  $q$ select public.restore_subscription_type('77777777-0000-0000-0000-00000000000b') $q$,
  '42704', 'Тип абонемента не найден в архиве', 'Восстановление типа чужого центра — 42704'
);
select lives_ok(
  $q$ select public.restore_subscription_type('77777777-0000-0000-0000-000000000001') $q$,
  'Владелец восстанавливает свой тип абонемента'
);
select is(
  (select deleted_at from public.subscription_types where id = '77777777-0000-0000-0000-000000000001'),
  null,
  'Тип абонемента снова живой после restore_subscription_type'
);

reset role;


-- 23-24. Отложенный триггер ловит именно нулевой default, а не CHECK/индекс -----

-- CHECK и партиал-индекс attendance_statuses_center_default_idx (0008) не
-- видят эту строку как нарушение: is_default=false, deleted_at не тронут.
-- Единственный, кто ловит «в центре не осталось default» — этот триггер, и
-- ловит он только на коммите: set local role postgres (по умолчанию здесь,
-- после reset role) — грант is_default вне игры, тестируем сам триггер.
select lives_ok(
  $q$ update public.attendance_statuses set is_default = false
       where center_id = 'cccccccc-0000-0000-0000-00000000000a' and is_default and deleted_at is null $q$,
  'Прямой сброс единственного default проходит синхронно'
);
select throws_ok(
  $q$ set constraints public.attendance_statuses_check_default immediate $q$,
  '22023', 'В центре должен быть ровно один статус посещения по умолчанию',
  'Принудительная проверка отложенного триггера ловит нулевой default'
);

select * from finish();

rollback;
