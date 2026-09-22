-- =============================================================================
-- 0048_ai_job_goals.sql — список целей ребёнка для промпта модели
--
-- Живая приёмка 22.09.2026: системный промпт GPT-4o требует «goal_id бери
-- только из списка целей», а списка в промпте нет — ai_job_begin (0042)
-- отдаёт воркеру лишь file_id, center_id, lesson_id, student_id. Модель
-- придумала goal_id = "sound_R", ai_write_lesson_note упал на касте в uuid,
-- оплаченный черновик откатился. Заплатка в n8n (`delete model.goals`)
-- спасла резюме и SOAP ценой оценок по целям. Промт этапа 7 с самого
-- начала обещал моделью «транскрипт + цели ученика».
--
-- Решения (ревью архитектора до написания):
--
--   Р1. Список отдаёт та же ai_job_begin, а не новая функция: она уже
--       security definer без сессии, уже знает ребёнка диктовки и уже
--       закрыта грантами на bot_worker. Ключ — student_goals, элементы —
--       goal_id, title, area, sound, stage_title. Имя goal_id одно и в
--       списке, и в ответе модели, и в p.goals для ai_write_lesson_note:
--       два массива с полем id и goal_id в одном узле путаются молча, и
--       фильтр воркера отбрасывал бы всё, не сказав ни слова.
--
--   Р2. Ни одно ПОЛЕ списка не называет ребёнка: ни имени, ни
--       плательщика, ни диагноза, ни custom_fields. Привязка к ребёнку
--       живёт только в базе. target_date, last_score и note из
--       goal_progress не отдаются: note — внутренняя пометка специалиста
--       (0046), last_score подталкивает модель подгонять оценку под
--       прошлую. Ассерт pgTAP фиксирует состав полей поимённо — чтобы
--       «добавим имя для контекста» падало тестом. Что схема не держит:
--       title — свободный текст специалиста, и «Айсулуу — [р] в слогах»
--       туда написать можно; это тот же класс, что имена в транскрипте,
--       закрывается подсказкой на экране заведения цели, не констрейнтом.
--
--   Р3. Только status = 'active'. Это уже, чем принимает
--       ai_write_lesson_note (любая неудалённая цель ребёнка), и это
--       решение: список — то, что можно оценивать сегодня. Диктовка про
--       цель на паузе оценку не получит; специалист узнаёт об этом из
--       сообщения воркера (n8n/README.md). Расхождение с
--       ai_write_lesson_note мирит только фильтр воркера (Р8) — принято
--       сознательно: переиздавать ai_write_lesson_note в этой миграции не
--       стали, пропуск неактивной цели как skip в ней — отдельная правка.
--
--   Р4. coalesce(jsonb_agg(...), '[]') — jsonb_agg на пустом наборе даёт
--       null, а null в воркере роняет .map до ai_job_fail: событие висит
--       claimed, release_stale_claims возвращает его, ai_job_begin в
--       восьмиминутном окне отвечает null, воркер делает ack — оплаченная
--       диктовка исчезает молча. Пустой массив — штатный ответ, и pgTAP
--       сравнивает именно с '[]'::jsonb.
--
--   Р5. Порядок детерминирован: (stage.sort, created_at, id) — тот же
--       третий ключ, что 0046 Р1. goal_stages.sort не уникален (default 0,
--       справочник правит центр), created_at совпадает у целей одного
--       insert. Иначе промпт менялся бы между прогонами на одних данных.
--
--   Р6. Не больше 50 с отдельным ключом student_goals_total: молчаливое
--       усечение спрятало бы ровно ту цель, про которую диктовали. Какие
--       50 — первые по (этап, дата, id): при усечении выпадают самые
--       поздние этапы (дифференциация, связная речь). 50 активных целей
--       у одного ребёнка — проблема данных, а не промпта; воркер обязан
--       сказать специалисту, что список показан не весь, а какие именно
--       выпали — видно по порядку.
--
--   Р7. Ответ ai_job_begin перестаёт быть набором идентификаторов и
--       становится клиникой. revoke переиздаётся явно; сплошной забор
--       0007_function_grants (белый список для authenticated, пусто для
--       PUBLIC) ловит любой лишний грант и уже перечисляет ai_job_begin.
--       Новый ассерт здесь один — положительный на bot_worker;
--       отрицательные продублированы умышленно, чтобы отказ читался рядом
--       с причиной. В n8n у воркфлоу poll должно быть выключено
--       сохранение данных выполнений — иначе формулировки целей оседают в
--       БД n8n рядом с транскриптом (n8n/README.md).
--
--   Р8. Принятый риск, записанный с ценой. Защита «goal_id только из
--       списка» после 0048 живёт в Code-узле n8n, которого нет в
--       репозитории (владелец откатил begin/exception в
--       ai_write_lesson_note). Ошибка в узле — модель вернула выдуманный
--       или чужой goal_id — по-прежнему стоит всей оплаченной диктовки:
--       22P02 или 42704 откатывают заметку целиком, ai_job_fail ставит
--       терминал. Буквальный текст фильтра и правило «при любой ошибке
--       разбора goals слать заметку БЕЗ ключа goals» — в n8n/README.md как
--       именованный инвариант наравне с порядком узлов. pgTAP этого не
--       проверит; Р5 из 0042 (42704 на чужую цель) остаётся последним
--       рубежом и намеренно не ослабляется.
--
-- create or replace: сигнатура (bigint) и тип jsonb не меняются. Тело —
-- 0042 дословно, плюс два ключа в возвращаемом объекте.

create or replace function public.ai_job_begin(p_event_id bigint)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_event   public.events;
  v_request public.lesson_voice_requests;
  v_job     public.ai_jobs;
  v_goals   jsonb;
  v_total   integer;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р3/Р7 (0042): событие принимается только живое, своё и захваченное.
  select * into v_event from public.events
   where id = p_event_id
     and type = 'lesson.voice_received'
     and processed_at is null
     and claimed_at is not null;
  if not found then
    return null;
  end if;

  select * into v_request from public.lesson_voice_requests
   where id = (v_event.payload ->> 'voice_request_id')::uuid;
  if not found then
    return null;
  end if;

  -- Р8 (0042): свежесть считается от диктовки, не от токена.
  if v_request.consumed_at is null or v_request.consumed_at < now() - interval '24 hours' then
    return null;
  end if;

  -- Б3 (0042): всё, на чём упадёт запись, проверяется ЗДЕСЬ — до Whisper
  -- и модели. Иначе отказ приходит после двух платных вызовов, работа
  -- становится терминальной, и диктовка не восстанавливается никогда.
  if v_request.center_id <> v_event.center_id then
    return null;
  end if;
  if not exists (
    select 1 from public.students s
     where s.id = v_request.student_id and s.deleted_at is null
  ) then
    return null;
  end if;
  if not exists (
    select 1 from public.lessons l
     where l.id = v_request.lesson_id and l.deleted_at is null and l.status <> 'cancelled'
  ) then
    return null;
  end if;
  if exists (
    select 1 from public.lesson_notes n
     where n.lesson_id = v_request.lesson_id and n.student_id = v_request.student_id
       and n.deleted_at is null
       and (n.status = 'approved'
            or (n.source = 'voice' and n.conduct_key is distinct from v_request.id))
  ) then
    return null;
  end if;

  select * into v_job from public.ai_jobs where event_id = p_event_id for update;

  if found then
    -- Р4 (0042): сделанное и терминальное не переигрывается — n8n сразу ack.
    if v_job.status in ('done', 'failed') then
      return null;
    end if;
    -- В2 (0042): пока прогон свеж, работа занята. Без этого
    -- release_stale_claims возвращает событие за спину живому обработчику,
    -- и Whisper с моделью оплачиваются второй раз. Порог меньше того, с
    -- которым очередь возвращает пачки (10 минут), — иначе окна не
    -- остаётся вовсе.
    if v_job.started_at > now() - interval '8 minutes' then
      return null;
    end if;
    update public.ai_jobs
       set attempts = attempts + 1, started_at = now()
     where event_id = p_event_id;
  else
    -- В7 (0042): голый insert на гонке двух прогонов падал бы на первичном
    -- ключе, и воркер разобрал бы это как сбой — терминал по причине,
    -- которой нет.
    insert into public.ai_jobs (event_id, center_id)
    values (p_event_id, v_event.center_id)
    on conflict (event_id) do nothing
    returning * into v_job;

    if v_job.event_id is null then
      return null;
    end if;
  end if;

  -- 0048 Р1–Р6: активные цели ребёнка диктовки, обезличенно, в
  -- детерминированном порядке, не больше 50, с полным числом отдельно.
  -- Один проход: предикат «активная цель» написан один раз, список и
  -- полное число не могут разойтись при следующей правке фильтра.
  select coalesce(jsonb_agg(jsonb_build_object(
           'goal_id',     x.id,
           'title',       x.title,
           'area',        x.area,
           'sound',       x.sound,
           'stage_title', x.stage_title
         ) order by x.stage_sort, x.created_at, x.id) filter (where x.rn <= 50), '[]'::jsonb),
         coalesce(max(x.total), 0)::integer
    into v_goals, v_total
    from (
      select g.id, g.title, g.area, g.sound, st.title as stage_title, st.sort as stage_sort, g.created_at,
             row_number() over (order by st.sort, g.created_at, g.id) as rn,
             count(*) over () as total
        from public.goals g
        join public.goal_stages st on st.id = g.stage_id
       where g.student_id = v_request.student_id
         and g.center_id = v_request.center_id
         and g.deleted_at is null
         and g.status = 'active'
    ) x;

  return jsonb_build_object(
    'file_id',             v_event.payload ->> 'file_id',
    'center_id',           v_request.center_id,
    'lesson_id',           v_request.lesson_id,
    'student_id',          v_request.student_id,
    'student_goals',       v_goals,
    'student_goals_total', v_total
  );
end;
$$;

comment on function public.ai_job_begin(bigint) is
  'Занять событие до похода в платные API. null значит «не работай»: событие чужое, устаревшее, уже сделанное, терминальное, или запись всё равно упадёт (0042 Б3). С 0048 отдаёт student_goals — активные цели ребёнка диктовки без чего-либо, идентифицирующего ребёнка (goal_id, title, area, sound, stage_title; порядок этап→дата→id; не больше 50, полное число в student_goals_total). Место для квоты этапа 8 — здесь, до траты.';

revoke all on function public.ai_job_begin(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_begin(bigint) to bot_worker;
