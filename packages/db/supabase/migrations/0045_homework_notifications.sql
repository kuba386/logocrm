-- =============================================================================
-- 0045_homework_notifications.sql — доставка уведомлений по домашним заданиям
-- (этап 7c, попутная находка при решении про видео к ДЗ)
--
-- Цикл «выдал → сдал → проверил» немой уже сегодня, независимо от решения
-- передавать видео через WhatsApp специалиста. homework.reviewed не
-- эмитился вовсе; homework.assigned/homework.submitted эмитировались, но
-- никуда не доставлялись: не было ни строки в белом списке типов, ни
-- шаблонов, ни ветки в event_messages — событие падало в общий else
-- return, ноль получателей, notification_skip, неотличимо от «получателей
-- нет» в журнале.
--
-- Решения:
--   Р1. Адресат homework.submitted — специалист, а не родитель и не вся
--       администрация: первый в проекте случай уведомления не по
--       «плательщик» и не по «вся администрация». Три круга по убыванию
--       точности, каждый со своим механизмом отказа:
--         1) специалист ЗАНЯТИЯ, на котором задание выдано
--            (homework.lesson_id → lessons.effective_teacher_id —
--            учитывает замену) — если он ещё состоит в центре;
--         2) автор задания (homework.created_by), если он всё ещё в
--            центре и либо owner/admin, либо специалист, реально
--            ведущий ребёнка сейчас;
--         3) запасной круг — специалисты с неотменённым занятием с этим
--            ребёнком за последние 60 дней. Может дать больше одного
--            адресата — осознанный компромисс: лучше лишнее сообщение,
--            чем потерянное.
--       НЕ «все, кто видит клинику ребёнка» (clinical_teacher_sees) —
--       она намеренно бессрочна (0036 Р3): замещавший один раз в
--       сентябре получал бы уведомления о ДЗ этого ребёнка в следующем
--       году. Уволенный специалист (revoke_membership снимает membership,
--       но не telegram_accounts — 0033 Р1) продолжал бы получать имена
--       детей центра в личный чат. И одно submitted — одно действие
--       review_homework: адресат должен быть один по умолчанию, иначе
--       каждый решит, что проверит другой.
--   Р2. Правило видимости специалиста разделено на две части.
--       clinical_teacher_taught(teacher_id, student_id) — параметризованный
--       предикат «видел ли этот специалист этого ребёнка», годный для
--       контекста без сессии (доставка идёт от bot_worker, current_center()
--       и my_role() там пусты). clinical_teacher_sees(student_id) (0036)
--       переиздана как обёртка над ним для текущего пользователя — иначе
--       адресация под сессией воркера дала бы false всегда, и уведомления
--       снова не доставлялись бы никому, просто по другой причине.
--   Р3. Адресат всегда — результат запроса к memberships центра события,
--       а не значение, замороженное в payload. Между эмиссией и доставкой
--       лежат ретраи (до трёх, notification_begin), и участник мог за это
--       время уйти из центра.
--   Р4. Обе parent-ветки событий перечитывают строку homework на момент
--       доставки и не шлют, если она архивирована (тот же баг, что 0035
--       чинил для lesson.reminder: событие в очереди 18 часов, занятие
--       успевали отменить). homework.assigned шлётся НЕЗАВИСИМО от того,
--       что статус уже мог уйти дальше — факт выдачи не перестаёт быть
--       фактом. homework.submitted, наоборот, шлётся, только если статус
--       всё ещё submitted: напоминание «проверьте» после того, как уже
--       проверено, вводит в заблуждение.
--   Р5. review_homework переиздана: было «прочитать → проверить статус →
--       обновить без условия» — два специалиста (или двойной клик) могли
--       перезаписать чужой teacher_feedback без ошибки. Проверка и запись
--       теперь одним UPDATE ... WHERE ... AND status = 'submitted'.
--   Р6. Эмиссия homework.assigned перенесена из assign_homework в триггер
--       (branch INSERT), тем же местом, что submitted/reviewed. Раньше
--       было асимметрично: любой будущий путь, создающий строку homework
--       мимо assign_homework (бэкфилл, вторая RPC), родил бы задание без
--       уведомления, и тишина была бы неотличима от «родитель не
--       подключён».
--   Р7. Приватность — закрытым списком переменных шаблона, а не
--       формулировкой текста по умолчанию: в jsonb для рендера идут
--       только {child}/{due}, ни parent_note, ни free_text, ни
--       teacher_feedback там нет. Шаблоны редактирует центр
--       (upsert_message_template), и защититься можно только тем, что
--       колонок с этим текстом в наборе переменных нет физически —
--       render_template подставит только то, что пришло.
--   Р8. Платформенный дефолт homework.submitted/whatsapp_link — БЕЗ
--       {child}. У специалиста нет своей WhatsApp-кнопки в интерфейсе (она
--       есть только у плательщиков), поэтому канал whatsapp_link для него
--       не доставляет ничего — n8n сразу пишет notification_finish(no_channel)
--       — а строка с полным текстом «Родитель сдал ДЗ по <имя>» осталась бы
--       лежать в notification_log, которую администратор читает и, по
--       минимальному представлению об этом канале, стал бы копировать
--       вручную в свой личный WhatsApp. Это тот самый выход клиники из
--       защищённого канала, который 0043 уже ограничивал для отчёта.
--       Не менять этот текст на содержательный без нового решения.
--       Интерфейс настроек (apps/web/.../notifications) не предлагает
--       {child} для этого канала отдельной пустой подсказкой — решение
--       не защищено констрейнтом, но хотя бы не подсказывается само.
--
-- Второй раунд (ревью написанного SQL, до мержа, правки в том же файле —
-- миграция ещё не в main):
--   Р9.  Круг 1 фильтровал занятие только по id/center_id, без
--        deleted_at/status — специалист отменённого или архивированного
--        занятия оставался адресатом, хотя clinical_teacher_sees ему уже
--        отказывает. Условие взято из clinical_teacher_taught — не вторая
--        копия с другим набором условий.
--   Р10. Круги 1 и 3 искали адресата через memberships.teacher_id + role =
--        'teacher'. change_member_role (0004) обнуляет teacher_id при
--        смене роли, но НЕ трогает teachers.profile_id и не архивирует
--        карточку — специалист, ставший владельцем/админом, но
--        продолжающий вести детей, переставал быть адресатом молча, а
--        круг 3 отдавал его детей другим специалистам. Оба круга взяты
--        через teachers.profile_id (уникален на живую карточку — 0004,
--        индекс на (center_id, profile_id) — и переживает смену роли);
--        членство в центре по-прежнему проверяется явно, а не только
--        транзитивно через revoke_membership.
--   Р11. Запасной круг был ограничен только снизу (starts_at > now() - 60
--        дней) — специалист с будущим (ещё не проведённым) занятием тоже
--        считался адресатом. Интервал сделан двусторонним.
--   Р12. Круг 2 (автор-специалист) не проверял teachers.deleted_at —
--        архивированный специалист, пока сам ещё в центре, оставался
--        адресатом как автор, хотя круги 1 и 3 его уже исключают. Одно
--        правило «специалист жив» на все три круга.
--   Р13. submit_homework оставалась select-then-update, тот же класс
--        гонки, что Р5 закрывает у review_homework, — переиздана тем же
--        приёмом (условие в WHERE самого UPDATE). Оба атомарных UPDATE
--        дополнительно проверяют deleted_at is null: без этого архивация
--        между чтением и записью проверки/сдачи проходила бы тихо.
-- =============================================================================


-- 1. Видимость специалиста без сессии --------------------------------------------------------------

-- Параметризованная версия правила из clinical_teacher_sees (0036):
-- принимает кандидата явно, а не читает его из JWT. Нужна ровно потому,
-- что доставка идёт от bot_worker, где auth.uid()/my_teacher_id() пусты —
-- вызов исходной sessions-функции в этом контексте дал бы false всегда.
-- t.center_id = s.center_id в джойне — не для быстродействия: без него
-- функция была бы кросс-тенантным оракулом «кто кого учил» в момент,
-- когда её кто-нибудь по ошибке откроет для authenticated (сейчас — нет,
-- см. revoke ниже и tests/0007_function_grants.test.sql). tenant RLS не
-- даст создать занятие поперёк центров, но сама функция не должна на это
-- полагаться — она проверяет условие сама.
create or replace function public.clinical_teacher_taught(p_teacher_id uuid, p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select p_teacher_id is not null
     and exists (
       select 1
         from public.teachers t
         join public.students s on s.center_id = t.center_id
         join public.lesson_participants lp on lp.student_id = s.id
         join public.lessons l on l.id = lp.lesson_id
        where t.id = p_teacher_id
          and s.id = p_student_id
          and lp.deleted_at is null
          and l.deleted_at is null
          and l.status <> 'cancelled'
          and (l.teacher_id = p_teacher_id or l.substitute_teacher_id = p_teacher_id)
     );
$$;

comment on function public.clinical_teacher_taught(uuid, uuid) is
  'Видел ли ЭТОТ специалист этого ребёнка — параметризованная версия правила clinical_teacher_sees (0036), для контекстов без сессии. Один источник правила, чтобы условие про отменённые занятия не разъехалось по копиям (0043 уже держит одну такую копию руками в send_monthly_report). Требует общий центр учителя и ребёнка сама — не полагается только на RLS вызывающего (0045 Р-ревью).';

revoke all on function public.clinical_teacher_taught(uuid, uuid) from public, anon, authenticated, service_role;


-- Переиздание: обёртка над clinical_teacher_taught вместо инлайна.
-- Поведение не меняется — тот же результат для тех же входов, что и
-- версия 0036, только правило про занятие вынесено в общую функцию.
create or replace function public.clinical_teacher_sees(p_student_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(public.my_role(), '') = 'teacher'
     and public.clinical_teacher_taught(public.my_teacher_id(), p_student_id)
     and exists (
       select 1 from public.students s
        where s.id = p_student_id
          and s.center_id = public.current_center()
          and s.deleted_at is null
     );
$$;

comment on function public.clinical_teacher_sees(uuid) is
  'Видит ли специалист ТЕКУЩЕЙ сессии этого ребёнка: неотменённое занятие с ним, ребёнок не архивирован. Правило про занятие — в clinical_teacher_taught (0045), эта функция подставляет my_teacher_id() и добавляет проверку центра/архива. Срок доступа не ограничен сознательно (0036 Р3), отменённое занятие доступа не даёт (0036 Р10).';

revoke all on function public.clinical_teacher_sees(uuid) from public, anon;
grant execute on function public.clinical_teacher_sees(uuid) to authenticated;


-- 2. Адресация homework.submitted -------------------------------------------------------------------

-- Три круга, см. Р1. Возвращает user_id: обычно ровно один, в запасном
-- круге — возможно несколько.
create or replace function public.notification_homework_recipients(p_center_id uuid, p_homework_id uuid)
  returns table (user_id uuid)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_row       public.homework;
  v_recipient uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_homework_id and center_id = p_center_id and deleted_at is null;
  if not found then
    return;
  end if;

  -- Круг 1: специалист ЖИВОГО занятия, на котором задание выдано —
  -- deleted_at/status повторяют условие clinical_teacher_taught, а не
  -- берут вторую копию (Р9): специалист отменённого/архивированного
  -- занятия не должен оставаться адресатом, раз clinical_teacher_sees ему
  -- уже отказывает. Адресат — teachers.profile_id, а не
  -- memberships.teacher_id: карточка специалиста переживает смену его
  -- роли на owner/admin (change_member_role чистит только
  -- memberships.teacher_id — Р10), а членство в центре по-прежнему
  -- проверяется явно, а не только тем, что revoke_membership когда-то
  -- обнулит profile_id.
  if v_row.lesson_id is not null then
    select t.profile_id into v_recipient
      from public.lessons l
      join public.teachers t on t.id = l.effective_teacher_id and t.deleted_at is null
     where l.id = v_row.lesson_id
       and l.center_id = p_center_id
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and t.profile_id is not null
       and exists (
         select 1 from public.memberships m
          where m.center_id = p_center_id and m.user_id = t.profile_id
       )
     limit 1;
    if v_recipient is not null then
      return query select v_recipient;
      return;
    end if;
  end if;

  -- Круг 2: автор — если ещё в центре и (owner/admin) или (специалист,
  -- который сейчас реально ведёт ребёнка, и его карточка не архивирована —
  -- Р12: без этого условия архивированный автор оставался бы адресатом,
  -- хотя круги 1 и 3 его уже исключают). created_by сравнивается обычным
  -- «=», не is not distinct from: NULL здесь не должен ничего совпасть.
  if v_row.created_by is not null then
    select m.user_id into v_recipient
      from public.memberships m
      left join public.teachers t on t.id = m.teacher_id
     where m.center_id = p_center_id
       and m.user_id = v_row.created_by
       and (
         m.role in ('owner', 'admin')
         or (
           m.role = 'teacher'
           and t.deleted_at is null
           and public.clinical_teacher_taught(m.teacher_id, v_row.student_id)
         )
       )
     limit 1;
    if v_recipient is not null then
      return query select v_recipient;
      return;
    end if;
  end if;

  -- Круг 3: запасной — специалисты с занятием этого ребёнка за последние
  -- 60 дней, ДО текущего момента (Р11: раньше интервал был открыт сверху,
  -- и специалист с ещё не проведённым будущим занятием тоже считался
  -- адресатом). Тот же переход на teachers.profile_id, что в круге 1, и та
  -- же явная проверка живого членства.
  return query
    select distinct t.profile_id
      from public.teachers t
      join public.lessons l
        on (l.teacher_id = t.id or l.substitute_teacher_id = t.id)
       and l.deleted_at is null
       and l.status <> 'cancelled'
       and l.starts_at between now() - interval '60 days' and now()
      join public.lesson_participants lp
        on lp.lesson_id = l.id and lp.student_id = v_row.student_id and lp.deleted_at is null
     where t.center_id = p_center_id
       and t.deleted_at is null
       and t.profile_id is not null
       and exists (
         select 1 from public.memberships m
          where m.center_id = p_center_id and m.user_id = t.profile_id
       );
end;
$$;

comment on function public.notification_homework_recipients(uuid, uuid) is
  'Кому уведомление о сдаче ДЗ: специалист занятия → автор задания → все специалисты ребёнка за 60 дней (0045 Р1). НЕ clinical_teacher_sees — та бессрочна и продолжала бы слать замещавшему год назад.';

revoke all on function public.notification_homework_recipients(uuid, uuid) from public, anon, authenticated, service_role;


-- Тот же четырёхколоночный вид, что notification_targets/
-- notification_admin_targets (0034/0037) — event_messages зовёт все три
-- одинаково.
create or replace function public.notification_homework_targets(
  p_center_id  uuid,
  p_homework_id uuid,
  p_event_type text
)
  returns table (user_id uuid, channel text, chat_id bigint, template_text text)
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select r.user_id,
         case when a.chat_id is null then 'whatsapp_link' else 'telegram' end,
         a.chat_id,
         rt.message_text
    from public.notification_homework_recipients(p_center_id, p_homework_id) r
    left join public.telegram_accounts a
           on a.user_id = r.user_id and a.unlinked_at is null
    join lateral public.resolve_template(
           p_center_id, p_event_type,
           case when a.chat_id is null then 'whatsapp_link' else 'telegram' end
         ) rt on true
   where rt.should_send;
$$;

comment on function public.notification_homework_targets(uuid, uuid, text) is
  'Специалисты-получатели по заданию: канал и текст через resolve_template (0037), как у остальных *_targets. should_send в where — выключенный центром шаблон не даёт получателя вовсе.';

revoke all on function public.notification_homework_targets(uuid, uuid, text) from public, anon, authenticated, service_role;


-- 3. Триггер: три события вместо одного, включая эмиссию при выдаче ---------------------------------

-- Р6: assigned переехал сюда из assign_homework — один механизм на все
-- три перехода, а не два разных.
create or replace function public.homework_status_transition()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_rank constant jsonb := '{"assigned": 1, "submitted": 2, "reviewed": 3}'::jsonb;
begin
  if tg_op = 'INSERT' then
    perform public.emit_clinical_event('homework.assigned',
      jsonb_build_object('center_id', new.center_id, 'homework_id', new.id, 'student_id', new.student_id),
      new.center_id);
    return new;
  end if;

  if new.status is distinct from old.status
     and (v_rank ->> new.status)::int < (v_rank ->> old.status)::int then
    raise exception 'Нельзя вернуть задание из «%» в «%»', old.status, new.status
      using errcode = '23514';
  end if;

  if new.status = 'submitted' and old.status is distinct from 'submitted' then
    perform public.emit_clinical_event('homework.submitted',
      jsonb_build_object('center_id', new.center_id, 'homework_id', new.id, 'student_id', new.student_id),
      new.center_id);
  end if;

  if new.status = 'reviewed' and old.status is distinct from 'reviewed' then
    perform public.emit_clinical_event('homework.reviewed',
      jsonb_build_object('center_id', new.center_id, 'homework_id', new.id, 'student_id', new.student_id),
      new.center_id);
  end if;

  return new;
end;
$$;

revoke all on function public.homework_status_transition() from public, anon, authenticated, service_role;

drop trigger if exists homework_status_transition on public.homework;
create trigger homework_status_transition
  before insert or update on public.homework
  for each row execute function public.homework_status_transition();


-- Переиздание без emit_event: перенесён в триггер (Р6). Поведение вставки
-- не меняется ни в чём другом.
create or replace function public.assign_homework(
  p_student_id   uuid,
  p_free_text    text default null,
  p_exercise_ids uuid[] default '{}'::uuid[],
  p_lesson_id    uuid default null,
  p_due_on       date default null,
  p_conduct_key  uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_id     uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.students s
     where s.id = p_student_id and s.center_id = v_center and s.deleted_at is null
  ) then
    raise exception 'Ученик не найден' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_conduct_key is not null then
    select id into v_id from public.homework
     where student_id = p_student_id and conduct_key = p_conduct_key and deleted_at is null;
    if found then
      return v_id;
    end if;
  end if;

  insert into public.homework (center_id, student_id, lesson_id, due_on, free_text, conduct_key)
  values (v_center, p_student_id, p_lesson_id, p_due_on, p_free_text, p_conduct_key)
  returning id into v_id;

  -- Р7: дедуп по exercise_id, порядок — по первому вхождению; вся вставка
  -- атомарна — чужой центру exercise_id где угодно в списке откатывает всё.
  if coalesce(array_length(p_exercise_ids, 1), 0) > 0 then
    with items as (
      select exercise_id, min(ord) as sort
        from unnest(p_exercise_ids) with ordinality as u(exercise_id, ord)
       group by exercise_id
    )
    insert into public.homework_exercises (homework_id, exercise_id, center_id, sort)
    select v_id, exercise_id, v_center, sort from items order by sort;
  end if;

  return v_id;
end;
$$;

revoke all on function public.assign_homework(uuid, text, uuid[], uuid, date, uuid) from public, anon, authenticated, service_role;
grant execute on function public.assign_homework(uuid, text, uuid[], uuid, date, uuid) to authenticated;


-- Переиздание: Р13, тот же класс гонки, что Р5 закрывает ниже у
-- review_homework, — было «прочитать → проверить статус → обновить без
-- условия», двойной сабмит (двойной тап на плохой связи) молча
-- перезаписывал parent_note первого вызова.
create or replace function public.submit_homework(p_id uuid, p_parent_note text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.homework;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Задание не найдено' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or (v_role = 'parent' and public.parent_of_student(v_row.student_id))) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.homework
     set status = 'submitted', parent_note = coalesce(p_parent_note, parent_note)
   where id = p_id and status = 'assigned' and deleted_at is null;

  if not found then
    raise exception 'Задание уже отправлено или проверено' using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.submit_homework(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.submit_homework(uuid, text) to authenticated;


-- Переиздание: Р5, гонка «проверка — запись» устранена одним UPDATE с
-- условием по статусу вместо select-then-update. deleted_at is null в
-- самом UPDATE, не только в select выше, — иначе архивация между чтением
-- и записью прошла бы тихо: homework.reviewed эмитируется на
-- архивированной строке, а event_messages (Б4) её потом не доставит —
-- специалист решит, что отзыв ушёл, хотя он никуда не дошёл.
create or replace function public.review_homework(p_id uuid, p_teacher_feedback text default null)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.homework;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.homework
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Задание не найдено' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_row.student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.homework
     set status = 'reviewed', teacher_feedback = coalesce(p_teacher_feedback, teacher_feedback)
   where id = p_id and status = 'submitted' and deleted_at is null;

  if not found then
    raise exception 'Задание ещё не сдано или уже проверено' using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.review_homework(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.review_homework(uuid, text) to authenticated;


-- 4. Доставка --------------------------------------------------------------------------------------

insert into public.notification_event_types (event_type, description) values
  ('homework.assigned',  'Специалист выдал домашнее задание'),
  ('homework.submitted', 'Родитель сдал домашнее задание'),
  ('homework.reviewed',  'Специалист проверил домашнее задание')
on conflict (event_type) do nothing;

-- insert ... select ... where not exists, а не on conflict: 0043
-- пытался завести message_templates_default_key как один частичный
-- индекс с nulls not distinct на (center_id, event_type, channel), но имя
-- было уже занято индексом 0034 на (event_type, channel) where center_id
-- is null — create index if not exists тихо пропустил команду, реально
-- действует определение 0034. On conflict по такой паре частичных
-- индексов Postgres всё равно не вывел бы (42P10) — тот же урок, что в
-- 0043, но формулировка про «nulls not distinct» здесь была бы неточной.
insert into public.message_templates (center_id, event_type, channel, text)
select v.center_id, v.event_type, v.channel, v.text
  from (values
    (null::uuid, 'homework.assigned', 'telegram',
     'Специалист выдал домашнее задание для {child}. Срок — {due}. Посмотрите в приложении.'),
    (null::uuid, 'homework.assigned', 'whatsapp_link',
     'Здравствуйте! Специалисту выдано домашнее задание для {child}, срок — {due}. Посмотрите в приложении LogoCRM.'),
    (null::uuid, 'homework.submitted', 'telegram',
     'Родитель сдал домашнее задание по {child}. Загляните в приложение и оставьте отзыв.'),
    -- Р8: без {child} и без содержания — см. шапку. Не менять на
    -- содержательный текст: WhatsApp-канала у специалиста нет, эта строка
    -- живёт только в journal notification_log как no_channel.
    (null::uuid, 'homework.submitted', 'whatsapp_link',
     'Родитель сдал домашнее задание — откройте LogoCRM.'),
    (null::uuid, 'homework.reviewed', 'telegram',
     'Специалист проверил домашнее задание {child} и оставил отзыв. Посмотрите в приложении.'),
    (null::uuid, 'homework.reviewed', 'whatsapp_link',
     'Здравствуйте! Специалист оставил отзыв по домашнему заданию {child}. Посмотрите в приложении LogoCRM.')
  ) as v(center_id, event_type, channel, text)
 where not exists (
   select 1 from public.message_templates m
    where m.center_id is null
      and m.event_type = v.event_type
      and m.channel = v.channel
      and m.deleted_at is null
 );


-- Переиздание целиком (последняя версия — 0043, не 0034): три новых
-- ветки перед общей цепочкой student-событий. Обе parent-ветки перечитывают
-- homework на момент доставки (Р4).
create or replace function public.event_messages(p_event_id bigint)
  returns table (
    recipient_user_id uuid,
    channel           text,
    chat_id           bigint,
    message           text,
    subject_id        uuid,
    action            jsonb
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_tz       text;
  v_vars     jsonb := '{}'::jsonb;
  v_student  uuid;
  v_payer    uuid;
  v_lesson   record;
  v_homework public.homework;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if not found then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  v_tz := public.center_timezone(v_event.center_id);

  if v_event.type = 'lesson.reminder' then
    select l.starts_at, l.status, l.deleted_at, coalesce(t.full_name, '—') as teacher
      into v_lesson
      from public.lessons l
      left join public.teachers t on t.id = l.effective_teacher_id
     where l.id = (v_event.payload ->> 'lesson_id')::uuid;

    if not found or v_lesson.deleted_at is not null or v_lesson.status <> 'planned' then
      return;
    end if;

    v_vars := jsonb_build_object(
      'date',    to_char(v_lesson.starts_at at time zone v_tz, 'DD.MM.YYYY'),
      'time',    to_char(v_lesson.starts_at at time zone v_tz, 'HH24:MI'),
      'teacher', v_lesson.teacher
    );

    return query
      with participants as (
        select lp.student_id, s.full_name, s.payer_id
          from public.lesson_participants lp
          join public.students s on s.id = lp.student_id and s.deleted_at is null
         where lp.lesson_id = (v_event.payload ->> 'lesson_id')::uuid
           and lp.deleted_at is null
      )
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, v_vars || jsonb_build_object('child', p.full_name)),
             p.student_id,
             case when r.chat_id is null then null else jsonb_build_object(
               'label', 'Подтвердить приход',
               'callback_data', 'c:' || v_event.id::text || ':' || p.student_id::text
             ) end
        from participants p
        join lateral public.notification_targets(v_event.center_id, p.payer_id, v_event.type) r on true;
    return;
  end if;

  -- 0043: месячный отчёт. Текст уже заморожен в событии (Р4 из 0043) —
  -- здесь он только подставляется, ничего не пересчитывается.
  if v_event.type = 'report.monthly_ready' then
    v_student := (v_event.payload ->> 'student_id')::uuid;

    select s.payer_id into v_payer
      from public.students s
     where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'summary', coalesce(v_event.payload ->> 'summary', ''),
               'month',   to_char((v_event.payload ->> 'period_month')::date, 'MM.YYYY'),
               'child',   (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: выдано родителю. Шлём независимо от текущего статуса задания —
  -- факт выдачи не перестаёт быть фактом, даже если уже сдано (Р4).
  if v_event.type = 'homework.assigned' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student),
               'due',   coalesce(to_char(v_homework.due_on, 'DD.MM.YYYY'), 'без срока')
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  -- 0045: специалисту, что сдано. Шлём, только если статус ВСЁ ЕЩЁ
  -- submitted — напоминание «проверьте» после того, как уже проверено,
  -- вводит в заблуждение (Р4, в отличие от assigned выше).
  if v_event.type = 'homework.submitted' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found or v_homework.status <> 'submitted' then
      return;
    end if;

    v_student := v_homework.student_id;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_homework_targets(v_event.center_id, v_homework.id, v_event.type) r;
    return;
  end if;

  -- 0045: специалист проверил — родителю.
  if v_event.type = 'homework.reviewed' then
    select * into v_homework from public.homework h
     where h.id = (v_event.payload ->> 'homework_id')::uuid
       and h.center_id = v_event.center_id
       and h.deleted_at is null;
    if not found then
      return;
    end if;

    v_student := v_homework.student_id;
    select s.payer_id into v_payer from public.students s where s.id = v_student and s.deleted_at is null;
    if v_payer is null then
      return;
    end if;

    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'child', (select s.full_name from public.students s where s.id = v_student)
             )),
             v_student,
             null::jsonb
        from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
    return;
  end if;

  if v_event.type in ('subscription.low_balance', 'subscription.exhausted', 'student.absent_streak') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'left',  coalesce(v_event.payload ->> 'lessons_left', ''),
      'count', coalesce(v_event.payload ->> 'length', '')
    );
  elsif v_event.type in ('installment.due', 'installment.overdue') then
    v_student := (v_event.payload ->> 'student_id')::uuid;
    v_vars := jsonb_build_object(
      'amount', public.format_som((v_event.payload ->> 'amount_tiyin')::bigint),
      'date',   to_char((v_event.payload ->> 'due_date')::date, 'DD.MM.YYYY')
    );
  elsif v_event.type = 'digest.daily' then
    return query
      select r.user_id, r.channel, r.chat_id,
             public.render_template(r.template_text, jsonb_build_object(
               'date',    to_char((v_event.payload ->> 'date')::date, 'DD.MM.YYYY'),
               'lessons', coalesce(v_event.payload ->> 'lessons_today', '0'),
               'low',     coalesce(v_event.payload ->> 'low_balance', '0'),
               'debt',    public.format_som(coalesce((v_event.payload ->> 'debt_tiyin')::bigint, 0)),
               'overdue', coalesce(v_event.payload ->> 'installments_overdue', '0')
             )),
             null::uuid,
             null::jsonb
        from public.notification_admin_targets(v_event.center_id, v_event.type) r;
    return;
  else
    return;
  end if;

  select s.payer_id into v_payer
    from public.students s
   where s.id = v_student and s.deleted_at is null;

  if v_payer is null then
    return;
  end if;

  return query
    select r.user_id, r.channel, r.chat_id,
           public.render_template(r.template_text, v_vars || jsonb_build_object(
             'child', (select s.full_name from public.students s where s.id = v_student))),
           v_student,
           null::jsonb
      from public.notification_targets(v_event.center_id, v_payer, v_event.type) r;
end;
$$;

comment on function public.event_messages(bigint) is
  'Событие → кому и что отправить. Получатели, подстановка и формат денег — здесь, а не в сценарии n8n (0034 Р2). report.monthly_ready подставляет готовый текст из события (0043 Р4). Три ветки homework.* — 0045: assigned/reviewed идут родителю, submitted — специалисту через notification_homework_targets, обе перечитывают строку homework на момент доставки. Пустой результат значит «получателей нет» — воркер обязан записать это строкой skipped, а не промолчать.';

revoke all on function public.event_messages(bigint) from public, anon, authenticated, service_role;
grant execute on function public.event_messages(bigint) to bot_worker;
