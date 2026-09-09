-- =============================================================================
-- 0007_lock_down_participant_functions.sql
--
-- Исправление 0006. Там строка `revoke execute ... from public, anon` не
-- сняла грант с роли `authenticated`, а Supabase выдаёт EXECUTE и ей тоже.
-- В итоге четыре служебные функции оказались доступны любому залогиненному
-- пользователю по /rest/v1/rpc/. Нашёл линтер Supabase после применения.
--
-- Опаснее прочих rebuild_lesson_participants: security definer, принимает
-- произвольный lesson_id, читает lessons и students в обход RLS и в тексте
-- исключения возвращает ФИО ребёнка. Это оракул по именам между тенантами.
--
-- 0006 не правим — миграции неизменяемы после мержа.
-- =============================================================================


-- 1. Прямой вызов rebuild_lesson_participants запрещён --------------------------

-- Гранта после этой миграции нет, но проверку ставим и внутрь: один
-- неосторожный `grant` в будущей миграции иначе откроет функцию снова.
--
-- Проверять auth.uid() здесь нельзя. Функция работает внутри чужой
-- транзакции — при применении миграций, сидах и вызовах от service_role
-- пользователя нет, и любой insert в lessons начал бы падать.
--
-- Вместо этого проверяем происхождение вызова: оба легитимных пути идут из
-- триггеров, где pg_trigger_depth() >= 1. Прямой вызов через PostgREST даёт
-- ноль и отбивается независимо от грантов.
--
-- Если когда-нибудь понадобится пересобрать состав вручную, это делается не
-- вызовом функции, а «щекоткой» строки:
--   update public.lessons set status = status where id = ...;
-- Колонка status входит в `update of` у триггера, состав пересоберётся.
create or replace function public.rebuild_lesson_participants(p_lesson_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_lesson public.lessons;
  v_name   text;
begin
  if pg_trigger_depth() = 0 then
    raise exception 'rebuild_lesson_participants вызывается только из триггера'
      using errcode = '42501';
  end if;

  select * into v_lesson from public.lessons where id = p_lesson_id;

  if not found then
    delete from public.lesson_participants where lesson_id = p_lesson_id;
    return;
  end if;

  delete from public.lesson_participants where lesson_id = p_lesson_id;

  begin
    if v_lesson.student_id is not null then
      insert into public.lesson_participants
        (lesson_id, student_id, center_id, starts_at, ends_at, status, deleted_at)
      values
        (v_lesson.id, v_lesson.student_id, v_lesson.center_id,
         v_lesson.starts_at, v_lesson.ends_at, v_lesson.status, v_lesson.deleted_at);
    else
      -- Состав группы на дату занятия: вошёл не позже, вышел не раньше.
      insert into public.lesson_participants
        (lesson_id, student_id, center_id, starts_at, ends_at, status, deleted_at)
      select v_lesson.id, gs.student_id, v_lesson.center_id,
             v_lesson.starts_at, v_lesson.ends_at, v_lesson.status, v_lesson.deleted_at
        from public.group_students gs
       where gs.group_id = v_lesson.group_id
         and gs.deleted_at is null
         and gs.joined_at <= v_lesson.starts_at::date
         and (gs.left_at is null or gs.left_at > v_lesson.starts_at::date);
    end if;

  exception when exclusion_violation then
    -- Подменяем машинный текст на человеческий: имя ребёнка полезнее,
    -- чем имя констрейнта.
    select s.full_name into v_name
      from public.students s
     where s.id = coalesce(
             v_lesson.student_id,
             (select gs.student_id
                from public.group_students gs
                join public.lesson_participants lp on lp.student_id = gs.student_id
               where gs.group_id = v_lesson.group_id
                 and lp.deleted_at is null
                 and tstzrange(lp.starts_at, lp.ends_at) && tstzrange(v_lesson.starts_at, v_lesson.ends_at)
               limit 1));

    raise exception 'У ученика % уже есть занятие в это время',
      coalesce(v_name, 'из этой группы') using errcode = '23P01';
  end;
end;
$$;


-- 2. Снятие грантов ------------------------------------------------------------

-- ВАЖНО для будущих миграций: `security definer` на двух триггерных функциях
-- ниже теперь несёт нагрузку не только по RLS, но и по правам. Внутри них
-- current_user = postgres, владелец rebuild_lesson_participants, поэтому
-- вложенный вызов проходит несмотря на снятый грант. Если переписать их
-- через `create or replace` без `security definer`, вызов пойдёт от
-- authenticated и любая вставка занятия упадёт с permission denied.
--
-- Само срабатывание триггера гранта не требует: EXECUTE проверяется один раз,
-- в CREATE TRIGGER. Прецедент — audit_trigger(), закрытый в 0002 и 0003.
--
-- service_role грант сохраняет — сознательно, по конвенции 0003: это ключ
-- сервера, он и так ходит в обход RLS.
revoke execute on function
  public.rebuild_lesson_participants(uuid),
  public.lessons_participants_trigger(),
  public.group_students_participants_trigger(),
  public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid)
  from public, anon, authenticated;

-- Комментарий в 0006 утверждал, что гранта у authenticated нет. Он был
-- неверен: грант стоял по умолчанию. Утечки не случилось только потому, что
-- внутри функции есть проверка my_role(). Фиксируем факт в схеме.
comment on function public.lesson_slot_conflicts(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, uuid) is
  'Служебная. Отдаёт имена чужих учеников, поэтому недоступна прикладным ролям: вызывается только из create_lesson_series*, substitute_teacher и reschedule_lesson, которые сами security definer.';

comment on function public.rebuild_lesson_participants(uuid) is
  'Служебная. Вызывается только из триггеров — прямой вызов отбивается проверкой pg_trigger_depth().';
