-- =============================================================================
-- 0022_center_scoped_fks.sql — составные FK (id, center_id) на границах тенанта
--
-- Найдено при закрытии одной конкретной дыры (groups.teacher_id — тот же
-- класс, что lessons.teacher_id/substitute_teacher_id в 0017): в схеме были
-- ещё одноколоночные FK на таблицы тенанта на 12+ колонках, где RLS проверяет
-- только center_id своей строки, а центр ссылки — никто. Два раунда
-- architect-ревью (план и написанный код, эта сессия) сузили и уточнили
-- решение дважды:
--
--   Р1. Половинчатая изоляция хуже понятной дыры — правится вся схема одной
--       миграцией (groups/students/invitations/memberships/lessons/
--       group_students/lesson_participants), а не только groups.teacher_id.
--   Р2. FK — НЕ единственная защита для lessons.student_id/group_id и
--       group_students.group_id/student_id. AFTER-триггер lessons_sync_
--       participants (0006) вызывает rebuild_lesson_participants синхронно
--       ПОСЛЕ insert, и его обработчик exclusion_violation вставляет ФИО
--       ребёнка в текст ошибки без проверки центра. FK — даже немедленный,
--       не deferred — не гарантирует порядок относительно ДРУГИХ AFTER-
--       триггеров той же таблицы (оба типа триггеров упорядочены по имени;
--       "lessons_sync_participants" < "RI_ConstraintTrigger_..." лексически).
--       Единственная гарантия порядка в Postgres — BEFORE строго раньше
--       AFTER. Поэтому центр проверяется в новом BEFORE-триггере (раздел 3)
--       — до того, как AFTER-триггер успеет прочитать чужого ребёнка;
--       составной FK остаётся второй, структурной линией защиты.
--   Р3. Изначальный план делал все новые FK deferrable initially deferred
--       ради каскада `delete from centers`. Отклонено: (а) это не решает
--       Р2 — deferred делает проблему только хуже (проверка ещё дальше от
--       insert); (b) центры в проекте не удаляются жёстко нигде — insert/
--       delete на centers не выданы authenticated (0001, "INSERT/DELETE
--       напрямую запрещены"), только create_center(); операция вне
--       поддерживаемых путей продукта, инженерить под неё — то же
--       overengineering, от которого предостерегает CLAUDE.md; (c) deferred
--       ломает тестируемость pgTAP (проверка на COMMIT, файлы заканчиваются
--       rollback) без чистого способа доказать, что она вообще сработала.
--       Все новые FK — обычные, immediate, как lessons_teacher_fk в 0017.
--   Р4. group_students.group_id/student_id и students.payer_id — NOT NULL,
--       обнулить нельзя. Мягкое удаление (deleted_at) тоже не спасает
--       add constraint: FK проверяет все строки независимо от deleted_at.
--       Ремонт для них НЕ делается вовсе (тот же принцип, что уже был
--       выбран для lessons.student_id/group_id) — если такая строка
--       когда-нибудь найдётся на реальных данных, add constraint падает с
--       понятным именем констрейнта, и это осознанный отказ деплоя, а не
--       недосмотр.
--   Р5. memberships.payer_id и invitations.payer_id — та же дыра, что
--       teacher_id у тех же таблиц, только для родителя, не специалиста.
--       Упущена в первой версии, закрыта здесь же.
--   Р6. Первый прогон CI после написания кода уронил /app/students в
--       Playwright ("Всего: 0", хотя фикстура завела трёх детей): PostgREST
--       резолвит embedded-запрос (`students(...).select('...,payers(...)')`,
--       apps/web/app/app/students/page.tsx) по foreign key metadata, а на
--       students.payer_id теперь ДВА FK на payers — старый одноколоночный
--       (0005, students_payer_id_fkey) и новый составной (раздел 2). Между
--       двумя путями PostgREST не выбирает сам (PGRST201, "more than one
--       relationship was found"), запрос падает, страница молча показывает
--       пустой список (`const { data } = await ...`, ошибка не проверяется).
--       Та же неоднозначность — для каждой колонки этой миграции, даже там,
--       где сегодня никто её не embed'ит: подставить не 42704, а тихо
--       пустой список — расплата за то, что схема оставляет выбор клиенту
--       вместо того, чтобы иметь один-единственный путь связи. Раздел 2
--       поэтому не просто добавляет составные FK, а СНИМАЕТ старые
--       одноколоночные того же назначения — включая lessons_teacher_id_fkey/
--       lessons_substitute_teacher_id_fkey из 0006, которые с момента мержа
--       0017 точно так же дублируют lessons_teacher_fk/lessons_substitute_
--       teacher_fk и ничем, кроме везения (в apps/web ни разу не
--       понадобился embed lessons→teachers), не были замечены. Составной FK
--       при not null center_id строго сильнее одноколоночного — второй не
--       разрешает ничего, чего не разрешал бы первый, поэтому просто
--       снимается, а не остаётся "на всякий случай". ON DELETE переносится
--       на новый констрейнт как явный список колонок для SET NULL
--       (`on delete set null (col)`, PG15+ — здесь 17) там, где он был:
--       без списка колонок занулился бы и center_id, а он not null.
--
-- Разделы:
--   0. Недостающие unique (id, center_id) — groups, rooms.
--   1. Ремонт данных перед add constraint (иначе первая же чужая ссылка на
--      живой базе роняет весь деплой, а не ловится).
--   2. Составные FK, immediate (как 0017); каждый снимает старый
--      одноколоночный FK того же назначения (Р6), включая двух из 0017.
--   3. BEFORE-триггеры на lessons/group_students — единственная гарантия
--      порядка относительно AFTER-триггера синхронизации участников (Р2).
--   4. memberships — грант не закрывает прямой PATCH ролью owner/admin;
--      снимается и мёртвая после этого политика на запись.
--   5. create_lesson_series — читаемая ошибка вместо голого 23503 из
--      триггера раздела 3, и формулировка, которая не путает «чужой центр»
--      с «в архиве» (обе проверялись одним exists, текст был неточным).
-- =============================================================================


-- 0. Недостающие unique (id, center_id) ----------------------------------------

-- groups и rooms — единственные из таблиц тенанта, где его не завели раньше
-- (students/payers/lessons/services — 0008, teachers — 0017). Нужен как цель
-- для составных FK ниже.
alter table public.groups add constraint groups_id_center_key unique (id, center_id);
alter table public.rooms  add constraint rooms_id_center_key  unique (id, center_id);


-- 1. Ремонт данных перед add constraint -----------------------------------------

-- Именованная функция — тем же приёмом и по той же причине, что
-- backfill_student_payers_history (0014): чтобы тест мог позвать её явно,
-- а не полагаться на состояние базы на момент прогона. auth.uid() is not
-- null отбивает вызов из-под клиента — функция только для миграций/postgres.
--
-- Что сюда намеренно НЕ входит (Р4): lessons.student_id/group_id (check
-- (group_id is null) <> (student_id is null) не даёт обнулить одну сторону
-- без валидной замены), group_students.group_id/student_id и
-- students.payer_id (not null, обнулить нечем, а deleted_at всё равно не
-- спасает add constraint — FK проверяет все строки). Если такая строка
-- когда-нибудь найдётся на реальных данных — это чинится только руками,
-- глядя на конкретную запись, и должно уронить деплой с понятным именем
-- констрейнта, а не потеряться за тихим "ремонтом".
create or replace function public.repair_center_scoped_refs()
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.groups g set teacher_id = null
    from public.teachers t
   where t.id = g.teacher_id and t.center_id <> g.center_id;

  update public.groups g set room_id = null
    from public.rooms r
   where r.id = g.room_id and r.center_id <> g.center_id;

  update public.groups g set service_id = null
    from public.services s
   where s.id = g.service_id and s.center_id <> g.center_id;

  update public.students st set primary_teacher_id = null
    from public.teachers t
   where t.id = st.primary_teacher_id and t.center_id <> st.center_id;

  update public.invitations i set teacher_id = null
    from public.teachers t
   where t.id = i.teacher_id and t.center_id <> i.center_id;

  update public.invitations i set payer_id = null
    from public.payers p
   where p.id = i.payer_id and p.center_id <> i.center_id;

  update public.memberships m set teacher_id = null
    from public.teachers t
   where t.id = m.teacher_id and t.center_id <> m.center_id;

  update public.memberships m set payer_id = null
    from public.payers p
   where p.id = m.payer_id and p.center_id <> m.center_id;

  update public.lessons l set room_id = null
    from public.rooms r
   where r.id = l.room_id and r.center_id <> l.center_id;

  update public.lessons l set service_id = null
    from public.services s
   where s.id = l.service_id and s.center_id <> l.center_id;

  -- lesson_participants — не бизнес-запись, а денормализация ради EXCLUDE
  -- (комментарий на таблице, 0006): пересобирается триггером из lessons/
  -- group_students, строки здесь просто убираются, как и в
  -- rebuild_lesson_participants, а не архивируются.
  delete from public.lesson_participants lp
   using public.lessons l
  where lp.lesson_id = l.id and l.center_id <> lp.center_id;

  delete from public.lesson_participants lp
   using public.students st
  where lp.student_id = st.id and st.center_id <> lp.center_id;
end;
$$;

revoke execute on function public.repair_center_scoped_refs() from public, anon, authenticated;

select public.repair_center_scoped_refs();


-- 2. Составные FK ---------------------------------------------------------------
--
-- Имена старых одноколоночных FK — автоматические (Postgres называет их
-- "<таблица>_<колонка>_fkey" по умолчанию), сверены напрямую в проде через
-- Supabase MCP (только чтение — pg_constraint/pg_get_constraintdef), а не
-- предположены: ошибка в имени здесь молча оставила бы дыру embedding (Р6)
-- незакрытой, ничего не сообщив.

alter table public.groups drop constraint if exists groups_teacher_id_fkey;
alter table public.groups
  add constraint groups_teacher_fk foreign key (teacher_id, center_id)
  references public.teachers (id, center_id) on delete set null (teacher_id);

alter table public.groups drop constraint if exists groups_room_id_fkey;
alter table public.groups
  add constraint groups_room_fk foreign key (room_id, center_id)
  references public.rooms (id, center_id) on delete set null (room_id);

alter table public.groups drop constraint if exists groups_service_id_fkey;
alter table public.groups
  add constraint groups_service_fk foreign key (service_id, center_id)
  references public.services (id, center_id) on delete set null (service_id);

alter table public.students drop constraint if exists students_primary_teacher_id_fkey;
alter table public.students
  add constraint students_primary_teacher_fk foreign key (primary_teacher_id, center_id)
  references public.teachers (id, center_id) on delete set null (primary_teacher_id);

alter table public.students drop constraint if exists students_payer_id_fkey;
alter table public.students
  add constraint students_payer_fk foreign key (payer_id, center_id)
  references public.payers (id, center_id) on delete restrict;

alter table public.invitations drop constraint if exists invitations_teacher_id_fkey;
alter table public.invitations
  add constraint invitations_teacher_fk foreign key (teacher_id, center_id)
  references public.teachers (id, center_id) on delete cascade;
-- payer_id — без предшественника, добавляется просто.
alter table public.invitations
  add constraint invitations_payer_fk foreign key (payer_id, center_id)
  references public.payers (id, center_id);

-- memberships.teacher_id/payer_id — до сих пор вообще без FK: 0001 писался
-- раньше teachers/payers (0004), «заполняется, когда появится карточка»
-- осталось только комментарием, предшественника нет. Ни cascade, ни set
-- null: снос карточки специалиста/плательщика не должен молча менять
-- доступ участника к центру.
alter table public.memberships
  add constraint memberships_teacher_fk foreign key (teacher_id, center_id)
  references public.teachers (id, center_id);
alter table public.memberships
  add constraint memberships_payer_fk foreign key (payer_id, center_id)
  references public.payers (id, center_id);

-- lessons.teacher_id/substitute_teacher_id: составной FK уже есть с 0017
-- (lessons_teacher_fk/lessons_substitute_teacher_fk) — снимается только
-- старый одноколоночный-дубликат (Р6), составной пересоздаётся с явным
-- ON DELETE вместо унаследованного NO ACTION, чтобы восстановить исходное
-- поведение single-column предшественника (restrict/set null), а не просто
-- то, что случайно осталось после 0017.
alter table public.lessons drop constraint if exists lessons_teacher_id_fkey;
alter table public.lessons drop constraint if exists lessons_teacher_fk;
alter table public.lessons
  add constraint lessons_teacher_fk foreign key (teacher_id, center_id)
  references public.teachers (id, center_id) on delete restrict;

alter table public.lessons drop constraint if exists lessons_substitute_teacher_id_fkey;
alter table public.lessons drop constraint if exists lessons_substitute_teacher_fk;
alter table public.lessons
  add constraint lessons_substitute_teacher_fk foreign key (substitute_teacher_id, center_id)
  references public.teachers (id, center_id) on delete set null (substitute_teacher_id);

alter table public.lessons drop constraint if exists lessons_student_id_fkey;
alter table public.lessons
  add constraint lessons_student_fk foreign key (student_id, center_id)
  references public.students (id, center_id) on delete cascade;

alter table public.lessons drop constraint if exists lessons_group_id_fkey;
alter table public.lessons
  add constraint lessons_group_fk foreign key (group_id, center_id)
  references public.groups (id, center_id) on delete cascade;

alter table public.lessons drop constraint if exists lessons_room_id_fkey;
alter table public.lessons
  add constraint lessons_room_fk foreign key (room_id, center_id)
  references public.rooms (id, center_id) on delete set null (room_id);

alter table public.lessons drop constraint if exists lessons_service_id_fkey;
alter table public.lessons
  add constraint lessons_service_fk foreign key (service_id, center_id)
  references public.services (id, center_id) on delete set null (service_id);

alter table public.group_students drop constraint if exists group_students_group_id_fkey;
alter table public.group_students
  add constraint group_students_group_fk foreign key (group_id, center_id)
  references public.groups (id, center_id) on delete cascade;

alter table public.group_students drop constraint if exists group_students_student_id_fkey;
alter table public.group_students
  add constraint group_students_student_fk foreign key (student_id, center_id)
  references public.students (id, center_id) on delete cascade;

alter table public.lesson_participants drop constraint if exists lesson_participants_lesson_id_fkey;
alter table public.lesson_participants
  add constraint lesson_participants_lesson_fk foreign key (lesson_id, center_id)
  references public.lessons (id, center_id) on delete cascade;

alter table public.lesson_participants drop constraint if exists lesson_participants_student_id_fkey;
alter table public.lesson_participants
  add constraint lesson_participants_student_fk foreign key (student_id, center_id)
  references public.students (id, center_id) on delete cascade;


-- 3. BEFORE-триггеры: центр проверяется раньше AFTER-синхронизации участников ----

-- lessons_sync_participants (0006) — AFTER-триггер, вызывает
-- rebuild_lesson_participants синхронно после insert/update. Его обработчик
-- exclusion_violation читает students.full_name без фильтра по центру и
-- вставляет имя в текст ошибки — если бы до него дошла строка с чужим
-- student_id, ФИО чужого ребёнка ушло бы в браузер администратора другого
-- центра. FK из раздела 2 (даже немедленный) НЕ гарантирует, что сработает
-- раньше: порядок между двумя AFTER-триггерами одной таблицы не определён
-- относительно друг друга (оба упорядочены по имени). Единственная гарантия
-- Postgres — BEFORE строго раньше AFTER, поэтому проверка здесь.
--
-- Проверяется только center_id — не deleted_at: это не то же самое, что
-- бизнес-проверка "доступен ли" (deleted_at is null) в create_lesson_series
-- (раздел 5) — конфликтовать они не должны, каждая отвечает за своё.
create or replace function public.lessons_check_center_refs()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if new.teacher_id is not null and not exists (
     select 1 from public.teachers t where t.id = new.teacher_id and t.center_id = new.center_id
  ) then
    raise exception 'Специалист не найден в этом центре' using errcode = '42704';
  end if;

  if new.substitute_teacher_id is not null and not exists (
     select 1 from public.teachers t where t.id = new.substitute_teacher_id and t.center_id = new.center_id
  ) then
    raise exception 'Заменяющий специалист не найден в этом центре' using errcode = '42704';
  end if;

  if new.room_id is not null and not exists (
     select 1 from public.rooms r where r.id = new.room_id and r.center_id = new.center_id
  ) then
    raise exception 'Кабинет не найден в этом центре' using errcode = '42704';
  end if;

  if new.service_id is not null and not exists (
     select 1 from public.services s where s.id = new.service_id and s.center_id = new.center_id
  ) then
    raise exception 'Услуга не найдена в этом центре' using errcode = '42704';
  end if;

  if new.group_id is not null and not exists (
     select 1 from public.groups g where g.id = new.group_id and g.center_id = new.center_id
  ) then
    raise exception 'Группа не найдена в этом центре' using errcode = '42704';
  end if;

  if new.student_id is not null and not exists (
     select 1 from public.students st where st.id = new.student_id and st.center_id = new.center_id
  ) then
    raise exception 'Ученик не найден в этом центре' using errcode = '42704';
  end if;

  return new;
end;
$$;

drop trigger if exists lessons_check_center_refs on public.lessons;
create trigger lessons_check_center_refs
  before insert or update on public.lessons
  for each row execute function public.lessons_check_center_refs();

revoke execute on function public.lessons_check_center_refs() from public, anon, authenticated;

-- group_students_sync_participants (0006) — тот же класс: AFTER-триггер
-- зовёт rebuild_lesson_participants для будущих занятий группы, и падает
-- туда же, в тот же обработчик exclusion_violation.
create or replace function public.group_students_check_center_refs()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if not exists (
     select 1 from public.groups g where g.id = new.group_id and g.center_id = new.center_id
  ) then
    raise exception 'Группа не найдена в этом центре' using errcode = '42704';
  end if;

  if not exists (
     select 1 from public.students st where st.id = new.student_id and st.center_id = new.center_id
  ) then
    raise exception 'Ученик не найден в этом центре' using errcode = '42704';
  end if;

  return new;
end;
$$;

drop trigger if exists group_students_check_center_refs on public.group_students;
create trigger group_students_check_center_refs
  before insert or update on public.group_students
  for each row execute function public.group_students_check_center_refs();

revoke execute on function public.group_students_check_center_refs() from public, anon, authenticated;


-- 4. memberships — грант шире, чем нужно ------------------------------------------

-- insert/update/delete были открыты authenticated с 0001 («Права» в конце
-- файла). Ни один реальный путь записи им не пользуется: create_center
-- (insert owner), accept_invitation (insert), change_member_role (update
-- role/teacher_id — сам teacher_id не принимает, только зануляет при смене
-- роли), revoke_membership (delete) — все security definer, выполняются от
-- имени владельца функции и в грантах на таблицу не нуждаются. С открытым
-- грантом владелец/админ мог PATCH-ить role/teacher_id/payer_id любого
-- участника своего центра напрямую в обход этих проверок (например,
-- назначить себе teacher_id чужого специалиста и получить его данные через
-- my_teacher_id()) — составные FK из раздела 2 эту дыру не закрывают, они
-- не дают подставить участника чужого ЦЕНТРА, а не чужого участника своего
-- же центра.
revoke insert, update, delete on public.memberships from authenticated;

-- Мёртвая политика после revoke: без insert/update/delete-гранта
-- PostgREST отклоняет запрос раньше, чем RLS вообще посмотрит на политику.
-- Оставленная политика на запись при снятом гранте — приглашение будущему
-- автору вернуть грант "чтобы политика заработала", не думая о том, что
-- reader-only и был осознанным выбором этого раздела.
drop policy if exists memberships_write_admin on public.memberships;


-- 5. create_lesson_series — читаемая ошибка вместо голого 23503 ------------------

-- Раньше ни teacher_id, ни room_id/group_id/student_id/service_id не
-- проверялись на принадлежность центру внутри функции вообще (substitute_teacher
-- и accept_invitation такую проверку уже делают — 0011/0004, для create_lesson_series
-- её никогда не было). Без явной проверки здесь foreign_key_violation после
-- раздела 2 (или ошибка нового BEFORE-триггера раздела 3) уходила бы наружу
-- без detail, а весь UI серии построен на разборе detail — диалог конфликтов
-- показал бы пустоту вместо причины.
--
-- Формулировка "не найден в этом центре или в архиве", а не раздельные
-- "не найден"/"в архиве": один exists с deleted_at is null не может отличить
-- эти два случая, а два отдельных запроса ради текста — цена, которую этот
-- шаг не оправдывает. Раздельные тексты можно завести отдельной правкой,
-- если это понадобится администраторам на практике.
create or replace function public.create_lesson_series(p jsonb)
  returns table (lesson_id uuid, starts_at timestamptz)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center   uuid := public.current_center();
  v_series   uuid := gen_random_uuid();
  v_group    uuid := nullif(p ->> 'group_id', '')::uuid;
  v_student  uuid := nullif(p ->> 'student_id', '')::uuid;
  v_teacher  uuid := (p ->> 'teacher_id')::uuid;
  v_room     uuid := nullif(p ->> 'room_id', '')::uuid;
  v_service  uuid := nullif(p ->> 'service_id', '')::uuid;
  v_problems jsonb := '[]'::jsonb;
  v_late     jsonb;
  v_row      record;
  v_id       uuid;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if (v_group is null) = (v_student is null) then
    raise exception 'Укажите либо группу, либо ученика' using errcode = '22023';
  end if;

  if v_teacher is null then
    raise exception 'Укажите специалиста' using errcode = '22004';
  end if;

  if not exists (
     select 1 from public.teachers t
      where t.id = v_teacher and t.center_id = v_center and t.deleted_at is null
  ) then
    raise exception 'Специалист недоступен: не найден в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_room is not null and not exists (
     select 1 from public.rooms r
      where r.id = v_room and r.center_id = v_center and r.deleted_at is null
  ) then
    raise exception 'Кабинет недоступен: не найден в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_service is not null and not exists (
     select 1 from public.services s
      where s.id = v_service and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Услуга недоступна: не найдена в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_group is not null and not exists (
     select 1 from public.groups g
      where g.id = v_group and g.center_id = v_center and g.deleted_at is null
  ) then
    raise exception 'Группа недоступна: не найдена в этом центре или в архиве' using errcode = '42704';
  end if;

  if v_student is not null and not exists (
     select 1 from public.students st
      where st.id = v_student and st.center_id = v_center and st.deleted_at is null
  ) then
    raise exception 'Ученик недоступен: не найден в этом центре или в архиве' using errcode = '42704';
  end if;

  -- Сначала вся картина целиком.
  for v_row in select * from public.create_lesson_series_preview(p) loop
    if jsonb_array_length(v_row.conflicts) > 0 then
      v_problems := v_problems || jsonb_build_object(
        'day', v_row.day, 'starts_at', v_row.starts_at, 'conflicts', v_row.conflicts);
    end if;
  end loop;

  -- Серия против самой себя: одинаковые дни недели, пересекающиеся слоты
  -- внутри одного вызова. Сейчас на день приходится одно занятие, но правило
  -- должно пережить появление нескольких занятий в день — проверяем явно.
  if exists (
    select 1
      from public.series_dates(p) a
      join public.series_dates(p) b
        on a.day < b.day
       and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
  ) then
    raise exception 'Занятия внутри самой серии пересекаются' using errcode = '23P01';
  end if;

  if jsonb_array_length(v_problems) > 0 then
    raise exception 'Часть занятий пересекается с существующими — серия не создана'
      using errcode = '23P01', detail = v_problems::text;
  end if;

  for v_row in select * from public.series_dates(p) loop
    begin
      insert into public.lessons (
        center_id, service_id, teacher_id, room_id, group_id, student_id,
        starts_at, ends_at, series_id, notes
      )
      values (
        v_center, v_service, v_teacher, v_room,
        v_group, v_student, v_row.starts_at, v_row.ends_at, v_series, nullif(p ->> 'notes', '')
      )
      returning id into v_id;

    exception when exclusion_violation then
      -- Слот заняли между предпросмотром и вставкой. Констрейнт защитил
      -- данные, но клиенту нужен тот же формат ошибки, что и на обычном
      -- пути — иначе он не сможет показать, что именно случилось.
      v_late := public.lesson_slot_conflicts(
        v_center, v_teacher, v_room, v_group, v_student,
        v_row.starts_at, v_row.ends_at);

      if jsonb_array_length(v_late) = 0 then
        -- Конкурент успел откатиться, пока мы пересчитывали. Показать нечего,
        -- и повторять за админа не надо: пусть нажмёт сам, увидев актуальный
        -- предпросмотр. Автоповтор внутри функции опаснее лишнего клика.
        raise exception 'Слот был занят на момент сохранения, попробуйте ещё раз'
          using errcode = '23P01';
      end if;

      raise exception 'Слот заняли, пока заполнялась форма — серия не создана'
        using errcode = '23P01',
              detail = jsonb_build_array(jsonb_build_object(
                'day', v_row.day,
                'starts_at', v_row.starts_at,
                'conflicts', v_late
              ))::text;
    end;

    perform public.emit_event('lesson.created',
      jsonb_build_object('center_id', v_center, 'lesson_id', v_id,
                         'series_id', v_series, 'starts_at', v_row.starts_at), v_center);

    lesson_id := v_id;
    starts_at := v_row.starts_at;
    return next;
  end loop;
end;
$$;

revoke execute on function public.create_lesson_series(jsonb) from public, anon;
grant execute on function public.create_lesson_series(jsonb) to authenticated;
