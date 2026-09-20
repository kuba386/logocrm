-- =============================================================================
-- 0041_voice_summary.sql — голосовое резюме занятия (этап 7b)
--
-- Специалист диктует занятие в Telegram-бот, n8n скачивает аудио, Whisper
-- расшифровывает, Claude собирает черновик SOAP и родительского резюме.
-- Утверждает человек на экране — механика статусов из 0036/0038 не меняется.
--
-- Решения (план и его ревью — reports/stage-7.md, раздел «Plan — 7b»):
--   Р1. Черновик пишет функция для bot_worker с ОБРАТНОЙ проверкой
--       (auth.uid() is not null → отказ), как confirm_lesson_by_event (0035).
--       У n8n сессии нет, а write_lesson_note (0038) её требует.
--   Р2. Автор черновика — заказчик диктовки, а не NULL. lesson_notes.created_by
--       имеет default auth.uid(); у воркера сессии нет, значит NULL, а
--       approve_lesson_note (0038) пускает правку по created_by = auth.uid().
--       Сравнение с NULL даёт NULL — специалист не смог бы утвердить
--       собственный черновик, и выяснилось бы это только на живой приёмке.
--       Поэтому requested_by хранится в lesson_voice_requests и подставляется
--       явно. audit_log.user_id для такой записи всё равно NULL (триггер
--       аудита читает сессию) — автор восстанавливается по created_by
--       и source='voice'.
--   Р3. Payload события несёт только {center_id, voice_request_id, file_id}.
--       Занятие, ребёнок, специалист, заказчик, чат читаются из строки
--       запроса: один источник истины, подменить нечего. Побочно chat_id
--       специалиста не оседает в events.payload, который читают owner/admin.
--   Р4. Преднаборный захват (ai_jobs + ai_job_begin) — по образцу
--       notification_begin (0034). Очередь at-least-once: упавший ack_events
--       или детерминированный отказ вернули бы событие, и Whisper с Claude
--       оплачивались бы повторно, до трёх прогонов. ai_job_begin возвращает
--       null для уже сделанной или терминальной работы — n8n тогда сразу
--       ack_events, не ходя в API. Сюда же в этапе 8 встанет квота по
--       тарифу: ДО траты, а не после.
--   Р5. Каждая цель сверяется с ребёнком заметки. На групповом занятии
--       ребёнок Б — законный участник, поэтому clinical_check_lesson_participant
--       (0036) пропустит оценку по цели Б из диктовки про А. Констрейнтом это
--       не выразить: в goal_progress нет student_id.
--   Р6. Конфликт с ручной оценкой — on conflict do nothing, и пропущенные
--       цели возвращаются вызывающему. Ручной ввод весомее черновика, но
--       молчание неотличимо от «ИИ решил, что целей нет». Гарантию держит
--       частичный уникальный индекс (0036), а не предварительный select:
--       иначе параллельная ручная запись пролезет между проверкой и вставкой.
--   Р7. Права проверяются на момент диктовки, а не обработки. Идентичность
--       заморожена в строке запроса; ai_write_lesson_note НЕ перепроверяет
--       clinical_teacher_sees — терять работу с ребёнком потому, что через
--       три минуты отозвали членство, неправильно. Перепроверяется только то,
--       что относится к данным: занятие живо, ребёнок не архивирован,
--       заметка не утверждена.
--   Р8. expires_at работает только на отрезке «выдали → надиктовал».
--       Внутри ai_write_lesson_note его не проверяем: на любой задержке
--       очереди сработал бы ложно. Граница свежести обработки — сутки с
--       момента диктовки (consumed_at).
--   Р9. Один живой токен на пользователя: выдача нового гасит прежний, как
--       create_telegram_link_code (0033). Снимает неоднозначность поиска
--       записи по чату и даёт естественный ответ на «два голосовых подряд».
--  Р10. Гашение токена и эмиссия события — одна функция, одна транзакция.
--       Две дали бы окно: бот погасил, упал, не эмитил — голосовое исчезло,
--       на экране вечное ожидание.
--  Р11. check_ai_quota НЕ заводится. Функция с таким именем, которая всегда
--       пропускает, — ловушка: в этапе 8 её позовут, увидят «проверка есть»,
--       и лимита не появится. Реестр ai_usage пишется с первого дня, гейт
--       придёт вместе с тарифами и встанет в ai_job_begin.
--  Р12. Реестр пишется отдельной функцией сразу после каждого вызова API,
--       независимо от исхода записи заметки. Иначе при отказе деньги
--       потрачены, а учёта нет — ровно там, где расход аномальный. Источник
--       истины по деньгам — ai_usage; колонки в lesson_notes это витрина
--       одной суммы для карточки.
-- =============================================================================


-- 1. Запрос голосовой диктовки -------------------------------------------------------------------

create table if not exists public.lesson_voice_requests (
  id           uuid primary key default gen_random_uuid(),
  token        text not null,
  center_id    uuid not null references public.centers (id) on delete cascade,
  lesson_id    uuid not null,
  student_id   uuid not null,
  -- Подпись заметки. Права держит requested_by: у owner/admin
  -- my_teacher_id() пуст, и на teacher_id проверку строить нельзя (Р2).
  teacher_id   uuid,
  requested_by uuid not null references auth.users (id) on delete cascade,
  chat_id      bigint,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  armed_at     timestamptz,
  consumed_at  timestamptz,

  constraint lesson_voice_requests_lesson_fk
    foreign key (lesson_id, center_id) references public.lessons (id, center_id) on delete cascade,
  constraint lesson_voice_requests_student_fk
    foreign key (student_id, center_id) references public.students (id, center_id) on delete cascade,
  -- Отменённый токен (выдали новый, старый погасили) — законное состояние
  -- без armed_at: иначе пришлось бы подделывать «бот принял» у записи,
  -- которой бот не видел, и статистика «сколько диктовок дошло» врала бы.
  cancelled_at timestamptz,
  constraint lesson_voice_requests_cancelled_xor_consumed
    check (cancelled_at is null or consumed_at is null)
);

comment on table public.lesson_voice_requests is
  'Одноразовый токен «жду голосовое по этому ребёнку». Живёт минуты: выдан на экране, погашен голосовым в боте. Политик и грантов нет вовсе — токен возвращается один раз из RPC (прецедент telegram_link_codes, 0033).';

create unique index if not exists lesson_voice_requests_token_key
  on public.lesson_voice_requests (token);
-- Р9: один живой токен на пользователя.
create unique index if not exists lesson_voice_requests_live_idx
  on public.lesson_voice_requests (requested_by) where consumed_at is null and cancelled_at is null;
create index if not exists lesson_voice_requests_chat_idx
  on public.lesson_voice_requests (chat_id) where consumed_at is null and cancelled_at is null;

alter table public.lesson_voice_requests enable row level security;

revoke all on table public.lesson_voice_requests from public, anon, authenticated, service_role;

-- apply_audit здесь НЕ вызывается. audit_trigger кладёт всю строку в
-- audit_log, а его читают owner/admin центра — то есть токен и личный
-- chat_id специалиста утекли бы туда, ровно мимо решения Р3. Прецедент
-- telegram_link_codes (0033) аудита не имеет по той же причине.


create or replace function public.request_voice_note(p_lesson_id uuid, p_student_id uuid)
  returns text
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_uid     uuid := auth.uid();
  v_lesson  public.lessons;
  v_token   text;
begin
  if v_uid is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_lesson from public.lessons
   where id = p_lesson_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Занятие не найдено' using errcode = '42704';
  end if;
  if v_lesson.status = 'cancelled' then
    raise exception 'Занятие отменено' using errcode = '22023';
  end if;

  -- Р2: owner/admin тоже, а не только ведущий специалист — администратор
  -- закрывает занятие за заболевшего (0039 Р9).
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Всё, что можно отбить бесплатно, отбивается здесь: иначе отказ придёт
  -- после Whisper и Claude, то есть деньгами.
  if not exists (
    select 1 from public.lesson_participants lp
     where lp.lesson_id = p_lesson_id and lp.student_id = p_student_id and lp.deleted_at is null
  ) then
    raise exception 'Ребёнка нет в составе занятия' using errcode = '42704';
  end if;

  if exists (
    select 1 from public.lesson_notes n
     where n.lesson_id = p_lesson_id and n.student_id = p_student_id
       and n.deleted_at is null and n.status = 'approved'
  ) then
    raise exception 'Заметка уже утверждена — заведите новую на следующем занятии'
      using errcode = '23514';
  end if;

  -- Р9: прежний живой токен гасится, иначе старая ссылка остаётся рабочей.
  update public.lesson_voice_requests
     set cancelled_at = now()
   where requested_by = v_uid and consumed_at is null and cancelled_at is null;

  v_token := encode(extensions.gen_random_bytes(12), 'hex');

  insert into public.lesson_voice_requests
    (token, center_id, lesson_id, student_id, teacher_id, requested_by, expires_at)
  values
    (v_token, v_center, p_lesson_id, p_student_id,
     coalesce(v_lesson.substitute_teacher_id, v_lesson.teacher_id), v_uid,
     now() + interval '15 minutes');

  return v_token;
end;
$$;

comment on function public.request_voice_note(uuid, uuid) is
  'Кнопка «Отправьте голосовое» в строке ребёнка. Возвращает токен для deep-link t.me/<bot>?start=voice_<token>.';

revoke all on function public.request_voice_note(uuid, uuid) from public, anon, service_role;
grant execute on function public.request_voice_note(uuid, uuid) to authenticated;


-- 2. Бот: армирование и гашение ------------------------------------------------------------------

create or replace function public.arm_voice_request(p_token text, p_chat_id bigint)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_user uuid;
  v_row  public.lesson_voice_requests;
  v_name text;
begin
  -- Р1: вызывается только воркером без сессии.
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Отдельным if, а не частью предиката: telegram_user при непривязанном
  -- чате даёт NULL, и сравнение `not (... = requested_by)` молча не
  -- сработало бы — запись армировалась бы на чужой чат.
  v_user := public.telegram_user(p_chat_id);
  if v_user is null then
    raise exception 'Чат не привязан к аккаунту LogoCRM' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_voice_requests
   where token = p_token and consumed_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'Ссылка устарела — нажмите кнопку на экране занятия ещё раз'
      using errcode = '42704';
  end if;

  -- Р2: сравнивается пользователь, а не специалист.
  if v_row.requested_by <> v_user then
    raise exception 'Ссылка выдана другому пользователю' using errcode = '42501';
  end if;

  update public.lesson_voice_requests
     set chat_id = p_chat_id, armed_at = now()
   where id = v_row.id;

  select s.full_name into v_name from public.students s where s.id = v_row.student_id;

  return jsonb_build_object('student_name', v_name);
end;
$$;

comment on function public.arm_voice_request(text, bigint) is
  'Бот получил /start voice_<token>. Возвращает имя ребёнка: ответ «Записываю про Айсулуу» ловит диктовку не про того, пока её ещё можно переделать.';

revoke all on function public.arm_voice_request(text, bigint) from public, anon, authenticated, service_role;
grant execute on function public.arm_voice_request(text, bigint) to bot_worker;


create or replace function public.report_voice_note(
  p_chat_id  bigint,
  p_file_id  text,
  p_duration integer default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_row  public.lesson_voice_requests;
  v_name text;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;
  if coalesce(trim(p_file_id), '') = '' then
    raise exception 'Пустой файл' using errcode = '22023';
  end if;

  -- Р10: гашение и событие — одна транзакция. Ровно одна строка: у чата
  -- теоретически может оказаться несколько армированных записей, и гасить
  -- надо последнюю, а не все.
  update public.lesson_voice_requests
     set consumed_at = now()
   where id = (
     select r.id from public.lesson_voice_requests r
      where r.chat_id = p_chat_id
        and r.armed_at is not null
        and r.consumed_at is null
        and r.cancelled_at is null
        -- Окно считается от армирования, а не от выдачи токена: специалист
        -- нажал кнопку, отвлёкся на звонок, вошёл в чат на 13-й минуте и
        -- надиктовал четыре — диктовка уже произнесена, терять её нельзя.
        and r.armed_at > now() - interval '30 minutes'
      order by r.armed_at desc
      limit 1
      for update skip locked
   )
  returning * into v_row;

  if not found then
    raise exception 'Активной записи нет — нажмите «Записать резюме» на экране занятия'
      using errcode = '42704';
  end if;

  -- Р3: в payload только то, чего нет в строке запроса.
  perform public.emit_event_unchecked(
    'lesson.voice_received',
    jsonb_build_object(
      'center_id',        v_row.center_id,
      'voice_request_id', v_row.id,
      'file_id',          p_file_id,
      'duration',         p_duration
    ),
    v_row.center_id
  );

  select s.full_name into v_name from public.students s where s.id = v_row.student_id;

  return jsonb_build_object('student_name', v_name);
end;
$$;

comment on function public.report_voice_note(bigint, text, integer) is
  'Голосовое принято: гасит токен и кладёт событие одной транзакцией (Р10). Повторный апдейт Telegram не найдёт армированной записи и получит человеческий ответ.';

revoke all on function public.report_voice_note(bigint, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.report_voice_note(bigint, text, integer) to bot_worker;


-- 3. Очередь работ ИИ ----------------------------------------------------------------------------

create table if not exists public.ai_jobs (
  event_id    bigint primary key references public.events (id) on delete cascade,
  center_id   uuid not null references public.centers (id) on delete cascade,
  status      text not null default 'running'
                check (status in ('running', 'done', 'failed')),
  attempts    smallint not null default 0,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  last_error  text,

  constraint ai_jobs_finished_matches_status
    check ((status = 'running') = (finished_at is null))
);

comment on table public.ai_jobs is
  'Преднаборный захват дорогой работы (Р4). Очередь доставляет at-least-once, и без этой отметки рестарт n8n или отказ записи означали бы повторную оплату Whisper и Claude. Терминальный статус failed повтор не переигрывает.';

alter table public.ai_jobs enable row level security;
revoke all on table public.ai_jobs from public, anon, authenticated, service_role;


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
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Р3/Р7: событие принимается только живое, своё и захваченное.
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

  -- Р8: свежесть считается от диктовки, не от токена.
  if v_request.consumed_at is null or v_request.consumed_at < now() - interval '24 hours' then
    return null;
  end if;

  -- Б3: всё, на чём упадёт запись, проверяется ЗДЕСЬ — до Whisper и Claude.
  -- Иначе отказ приходит после двух платных вызовов, работа становится
  -- терминальной, и диктовка не восстанавливается никогда.
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
    -- Р4: сделанное и терминальное не переигрывается — n8n сразу ack.
    if v_job.status in ('done', 'failed') then
      return null;
    end if;
    -- В2: пока прогон свеж, работа занята. Без этого release_stale_claims
    -- возвращает событие за спину живому обработчику, и Whisper с Claude
    -- оплачиваются второй раз. Порог меньше того, с которым очередь
    -- возвращает пачки (10 минут), — иначе окна не остаётся вовсе.
    if v_job.started_at > now() - interval '8 minutes' then
      return null;
    end if;
    update public.ai_jobs
       set attempts = attempts + 1, started_at = now()
     where event_id = p_event_id;
  else
    -- В7: голый insert на гонке двух прогонов падал бы на первичном ключе,
    -- и воркер разобрал бы это как сбой — терминал по причине, которой нет.
    insert into public.ai_jobs (event_id, center_id)
    values (p_event_id, v_event.center_id)
    on conflict (event_id) do nothing
    returning * into v_job;

    if v_job.event_id is null then
      return null;
    end if;
  end if;

  return jsonb_build_object(
    'file_id',    v_event.payload ->> 'file_id',
    'center_id',  v_request.center_id,
    'lesson_id',  v_request.lesson_id,
    'student_id', v_request.student_id
  );
end;
$$;

comment on function public.ai_job_begin(bigint) is
  'Занять событие до похода в платные API. null значит «не работай»: событие чужое, устаревшее, уже сделанное или терминальное. Место для квоты этапа 8 — здесь, до траты (Р11).';

revoke all on function public.ai_job_begin(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_begin(bigint) to bot_worker;


create or replace function public.ai_job_finish(p_event_id bigint)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.ai_jobs
     set status = 'done', finished_at = now(), last_error = null
   where event_id = p_event_id and status = 'running';

  -- Обещание «аудио не храним» выполнимо не полностью: копия остаётся у
  -- Telegram. Но file_id из очереди убираем — по нему файл и достаётся.
  update public.events
     set payload = payload - 'file_id'
   where id = p_event_id and type = 'lesson.voice_received';
end;
$$;

revoke all on function public.ai_job_finish(bigint) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_finish(bigint) to bot_worker;


create or replace function public.ai_job_fail(p_event_id bigint, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid;
  v_request_id uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select e.center_id, (e.payload ->> 'voice_request_id')::uuid
    into v_center, v_request_id
    from public.events e where e.id = p_event_id;
  if v_center is null then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  -- Терминально: повтор упрётся в ai_job_begin → null и не потратит ни цента.
  update public.ai_jobs
     set status = 'failed', finished_at = now(), last_error = p_reason
   where event_id = p_event_id and status = 'running';

  update public.events
     set payload = payload - 'file_id'
   where id = p_event_id and type = 'lesson.voice_received';

  perform public.fail_events(array[p_event_id], p_reason);

  -- В1: без этого провал не виден вообще никому. ai_jobs закрыта грантами,
  -- event.failed до третьей попытки не дойдёт (работа терминальна уже
  -- сейчас), в чат ничего не уходит — на экране вечное ожидание, а в
  -- реестре списанные деньги без объяснения. Доставку в чат специалиста
  -- делает n8n тем же notification_begin/finish, что и успех.
  perform public.emit_event_unchecked(
    'lesson.voice_failed',
    jsonb_build_object(
      'center_id',        v_center,
      'voice_request_id', v_request_id,
      'reason',           p_reason
    ),
    v_center
  );
end;
$$;

comment on function public.ai_job_fail(bigint, text) is
  'Детерминированный отказ: ставит терминальный статус и возвращает событие в очередь только для журнала — повтор обработки уже не начнётся (Р4).';

revoke all on function public.ai_job_fail(bigint, text) from public, anon, authenticated, service_role;
grant execute on function public.ai_job_fail(bigint, text) to bot_worker;


-- 4. Реестр расхода ------------------------------------------------------------------------------

create table if not exists public.ai_usage (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null references public.centers (id) on delete cascade,
  event_id   bigint references public.events (id) on delete set null,
  kind       text not null check (kind in ('transcribe', 'summary')),
  model      text,
  tokens_in  integer not null default 0 check (tokens_in >= 0),
  tokens_out integer not null default 0 check (tokens_out >= 0),
  cost_tiyin integer not null default 0 check (cost_tiyin >= 0),
  -- Курс живёт в переменных n8n и устаревает. Единственное, что спасает
  -- историю, — возможность пересчитать её по токенам, поэтому курс
  -- записывается строкой рядом (Р12).
  rate_note  text,
  created_at timestamptz not null default now()
);

comment on table public.ai_usage is
  'Источник истины по деньгам за ИИ: по строке на каждый вызов API (Р12). Колонки model/tokens_*/cost_tiyin в lesson_notes — витрина одной суммы для карточки, не учёт. Закрыта на запись: пишет только ai_usage_record, иначе владелец правил бы собственный счётчик.';

create index if not exists ai_usage_center_idx on public.ai_usage (center_id, created_at desc);
-- Повтор вызова из n8n (таймаут на ответе PostgREST при прошедшей записи)
-- иначе кладёт вторую строку на тот же вызов API, и «источник истины по
-- деньгам» начинает врать. Законная вторая строка — другого kind.
create unique index if not exists ai_usage_event_kind_key
  on public.ai_usage (event_id, kind) where event_id is not null;

alter table public.ai_usage enable row level security;

-- Не apply_tenant_rls: она даёт owner/admin for all, то есть право
-- подчищать расход. Только чтение.
drop policy if exists ai_usage_admin_read on public.ai_usage;
create policy ai_usage_admin_read on public.ai_usage
  for select to authenticated
  using (center_id = public.current_center() and coalesce(public.my_role(), '') in ('owner', 'admin'));

revoke all on table public.ai_usage from public, anon, authenticated, service_role;
grant select on public.ai_usage to authenticated;


create or replace function public.ai_usage_record(
  p_event_id   bigint,
  p_kind       text,
  p_model      text,
  p_tokens_in  integer,
  p_tokens_out integer,
  p_cost_tiyin integer,
  p_rate_note  text default null
)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select center_id into v_center from public.events where id = p_event_id;
  if v_center is null then
    raise exception 'Событие не найдено' using errcode = '42704';
  end if;

  insert into public.ai_usage
    (center_id, event_id, kind, model, tokens_in, tokens_out, cost_tiyin, rate_note)
  values
    (v_center, p_event_id, p_kind, p_model,
     coalesce(p_tokens_in, 0), coalesce(p_tokens_out, 0), coalesce(p_cost_tiyin, 0), p_rate_note);
end;
$$;

comment on function public.ai_usage_record(bigint, text, text, integer, integer, integer, text) is
  'Зовётся сразу после каждого вызова API, независимо от исхода записи заметки: иначе при отказе деньги потрачены, а учёта нет — ровно там, где расход аномальный (Р12).';

revoke all on function public.ai_usage_record(bigint, text, text, integer, integer, integer, text)
  from public, anon, authenticated, service_role;
grant execute on function public.ai_usage_record(bigint, text, text, integer, integer, integer, text)
  to bot_worker;


-- check_ai_quota здесь НЕ заводится (Р11): функция с таким именем, которая
-- всегда пропускает, — ловушка для этапа 8. Экран /app/settings/ai питает
-- эта сводка, а блокирующий гейт придёт с тарифами и встанет в ai_job_begin.
create or replace function public.ai_usage_summary(p_from date, p_to date)
  returns table (kind text, calls integer, tokens_in bigint, tokens_out bigint, cost_tiyin bigint)
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null or coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  if p_from is null or p_to is null then
    raise exception 'Укажите период' using errcode = '22023';
  end if;

  -- Границы — в поясе центра, а не сервера: иначе вызовы с полуночи до
  -- шести утра по Бишкеку уезжают в соседний месяц, сумма за период не
  -- сходится со строками, и этап 8 будет тарифицировать по этим числам.
  return query
    select u.kind, count(*)::integer, sum(u.tokens_in)::bigint,
           sum(u.tokens_out)::bigint, sum(u.cost_tiyin)::bigint
      from public.ai_usage u
     where u.center_id = v_center
       and u.created_at >= (p_from::timestamp at time zone public.center_timezone(v_center))
       and u.created_at <  ((p_to + 1)::timestamp at time zone public.center_timezone(v_center))
     group by u.kind
     order by u.kind;
end;
$$;

revoke all on function public.ai_usage_summary(date, date) from public, anon, service_role;
grant execute on function public.ai_usage_summary(date, date) to authenticated;


-- 5. Предложенные ИИ оценки целей ----------------------------------------------------------------

-- Б1: ИИ НЕ пишет goal_progress напрямую. student_goals_brief (0036) отдаёт
-- родителю last_score прямо из goal_progress без всякого фильтра по
-- утверждению — то есть оценка, которую поставила модель и не смотрел
-- человек, появлялась бы в кабинете родителя через минуту после диктовки,
-- пока сам специалист видит ещё неутверждённый черновик. Главное обещание
-- этапа («публикует человек») для оценок не выполнялось бы вовсе.
--
-- Поэтому предложения лежат отдельно и переезжают в goal_progress только в
-- approve_lesson_note. Отдельной таблицей, а не jsonb в заметке: 0036 Р7
-- уже отказался от goals_touched jsonb ровно потому, что массив
-- идентификаторов ничем не проверяется и однажды покажет цель другого
-- ребёнка. Здесь связь держат составные FK и триггер.
create table if not exists public.lesson_note_goal_scores (
  id         uuid primary key default gen_random_uuid(),
  center_id  uuid not null references public.centers (id) on delete cascade,
  note_id    uuid not null,
  goal_id    uuid not null,
  score      integer not null check (score between 0 and 100),
  note       text,
  created_at timestamptz not null default now(),

  constraint lesson_note_goal_scores_note_fk
    foreign key (note_id, center_id) references public.lesson_notes (id, center_id) on delete cascade,
  constraint lesson_note_goal_scores_goal_fk
    foreign key (goal_id, center_id) references public.goals (id, center_id) on delete cascade,
  constraint lesson_note_goal_scores_pair_key unique (note_id, goal_id)
);

comment on table public.lesson_note_goal_scores is
  'Оценки целей, предложенные моделью. В goal_progress они попадают только при утверждении заметки человеком (Б1): родителю виден last_score из goal_progress без фильтра по статусу, поэтому запись туда напрямую обошла бы утверждение.';

create index if not exists lesson_note_goal_scores_note_idx
  on public.lesson_note_goal_scores (note_id);

-- Цель обязана принадлежать тому же ребёнку, что и заметка. Составной FK
-- этого не выражает: он проверяет только совпадение центра, а на групповом
-- занятии цель соседа — законная строка того же центра.
create or replace function public.lesson_note_goal_scores_check_student()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_student uuid;
  v_goal    uuid;
begin
  select n.student_id into v_student from public.lesson_notes n where n.id = new.note_id;
  select g.student_id into v_goal    from public.goals g        where g.id = new.goal_id;

  if v_student is null or v_goal is null or v_student <> v_goal then
    raise exception 'Оценка по цели другого ребёнка' using errcode = '42704';
  end if;

  return new;
end;
$$;

revoke all on function public.lesson_note_goal_scores_check_student()
  from public, anon, authenticated, service_role;

drop trigger if exists lesson_note_goal_scores_check_student on public.lesson_note_goal_scores;
create trigger lesson_note_goal_scores_check_student
  before insert or update on public.lesson_note_goal_scores
  for each row execute function public.lesson_note_goal_scores_check_student();

alter table public.lesson_note_goal_scores enable row level security;

-- Видно тем же, кому видна сама заметка: родителю таблица lesson_notes
-- закрыта целиком (0036 Р4), значит и предложения ему недоступны.
call public.apply_tenant_rls('lesson_note_goal_scores', false);

drop policy if exists lesson_note_goal_scores_teacher_read on public.lesson_note_goal_scores;
create policy lesson_note_goal_scores_teacher_read on public.lesson_note_goal_scores
  for select to authenticated
  using (
    center_id = public.current_center()
    and exists (
      select 1 from public.lesson_notes n
       where n.id = lesson_note_goal_scores.note_id and n.deleted_at is null
    )
  );

revoke all on table public.lesson_note_goal_scores from public, anon, authenticated, service_role;
grant select on public.lesson_note_goal_scores to authenticated;


-- Утверждение переиздаётся: вместе со статусом заметки переносит
-- предложенные оценки в goal_progress. До утверждения их нет нигде, кроме
-- экрана специалиста.
create or replace function public.approve_lesson_note(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
  v_row    public.lesson_notes;
  v_date   date;
  v_item   record;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_notes
   where id = p_id and center_id = v_center and deleted_at is null;
  if not found then
    raise exception 'Заметка не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or v_row.created_by = auth.uid()) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Повторное утверждение — холостой ход, а не ошибка (0038).
  if v_row.status = 'approved' then
    return;
  end if;

  update public.lesson_notes set status = 'approved' where id = p_id;

  select (l.starts_at at time zone public.center_timezone(v_center))::date
    into v_date
    from public.lessons l where l.id = v_row.lesson_id;

  -- Б2: conduct_key оставляем пустым и пропускаем цели, по которым за это
  -- занятие оценка уже есть. Занять ключ lesson_id нельзя: им гасит повторы
  -- complete_lesson (0039), и ручная оценка, поставленная ПОСЛЕ утверждения,
  -- молча не записалась бы — ровно тот отказ, который 0039 Р3 называет
  -- недопустимым. Так ручная всегда выигрывает, а потеряться не может
  -- ничего.
  for v_item in
    select s.goal_id, s.score, s.note
      from public.lesson_note_goal_scores s
     where s.note_id = p_id
       and not exists (
         select 1 from public.goal_progress gp
          where gp.goal_id = s.goal_id
            and gp.lesson_id = v_row.lesson_id
            and gp.deleted_at is null
       )
  loop
    insert into public.goal_progress
      (center_id, goal_id, lesson_id, date, score, note, created_by)
    values
      (v_center, v_item.goal_id, v_row.lesson_id,
       coalesce(v_date, public.center_today(v_center)), v_item.score, v_item.note,
       coalesce(v_row.created_by, auth.uid()));
  end loop;
end;
$$;

comment on function public.approve_lesson_note(uuid) is
  'Утверждение заметки. Вместе со статусом переносит предложенные моделью оценки в goal_progress: до этого момента их не видит ни родитель, ни витрина прогресса (0041 Б1).';

revoke all on function public.approve_lesson_note(uuid) from public, anon, service_role;
grant execute on function public.approve_lesson_note(uuid) to authenticated;


-- Переиздание write_lesson_note: править существующую заметку может тот,
-- кто видит ребёнка, а не только её автор.
--
-- В11: автором голосового черновика стал заказчик диктовки (Р2), а прежняя
-- версия пускала правку только автору или owner/admin. Занятие вёл один
-- специалист и надиктовал резюме, закрывает второй (замена, группа на
-- двоих) — complete_lesson идёт в write_lesson_note, получает 42501 и
-- падает ЦЕЛИКОМ: ни посещаемости, ни списания, ни статуса занятия.
-- Специалист видит «Недостаточно прав» на кнопке «Провести» без всякого
-- объяснения. Право по видимости ребёнка — тот же приём, что у
-- update_homework (0038 Р2).
create or replace function public.write_lesson_note(
  p_lesson_id      uuid,
  p_student_id     uuid,
  p_soap           jsonb default null,
  p_parent_summary text default null,
  p_teacher_id     uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center     uuid := public.current_center();
  v_role       text := coalesce(public.my_role(), '');
  v_teacher_id uuid;
  v_row        public.lesson_notes;
  v_id         uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  if v_center is null then
    raise exception 'Не определён центр' using errcode = '42501';
  end if;

  select * into v_row from public.lesson_notes
   where lesson_id = p_lesson_id and student_id = p_student_id
     and center_id = v_center and deleted_at is null;

  if found then
    -- Второй рубеж — триггер lesson_notes_lock_approved_content (0038);
    -- эта проверка только даёт понятное сообщение до похода в базу.
    if v_row.status = 'approved' then
      raise exception 'Утверждённую заметку нельзя изменить — заведите новую на следующем занятии'
        using errcode = '23514';
    end if;

    if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(p_student_id)) then
      raise exception 'Недостаточно прав' using errcode = '42501';
    end if;

    update public.lesson_notes
       set soap           = coalesce(p_soap, soap),
           parent_summary = coalesce(p_parent_summary, parent_summary)
     where id = v_row.id;

    return v_row.id;
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

  if v_role = 'teacher' then
    v_teacher_id := public.my_teacher_id();
  elsif p_teacher_id is not null then
    if not exists (select 1 from public.teachers t where t.id = p_teacher_id and t.center_id = v_center) then
      raise exception 'Специалист не найден' using errcode = '42704';
    end if;
    v_teacher_id := p_teacher_id;
  end if;

  insert into public.lesson_notes (center_id, lesson_id, student_id, teacher_id, soap, parent_summary)
  values (v_center, p_lesson_id, p_student_id, v_teacher_id, coalesce(p_soap, '{}'::jsonb), p_parent_summary)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.write_lesson_note(uuid, uuid, jsonb, text, uuid) from public, anon, service_role;
grant execute on function public.write_lesson_note(uuid, uuid, jsonb, text, uuid) to authenticated;


-- 6. Запись черновика ----------------------------------------------------------------------------

create or replace function public.ai_write_lesson_note(p_event_id bigint, p jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_event    public.events;
  v_request  public.lesson_voice_requests;
  v_note     public.lesson_notes;
  v_note_id  uuid;
  v_key      text;
  v_item     jsonb;
  v_goal     public.goals;
  v_score    integer;
  v_written  integer := 0;
  v_skipped  jsonb := '[]'::jsonb;
  v_date     date;
  v_inserted uuid;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Форма payload проверяется целиком, как в complete_lesson (0039 Р4):
  -- неизвестный ключ — явная ошибка с именем, а не тихо проигнорированный.
  for v_key in select jsonb_object_keys(coalesce(p, '{}'::jsonb)) loop
    if v_key not in ('soap', 'parent_summary', 'raw_transcript', 'goals', 'model',
                     'tokens_in', 'tokens_out', 'cost_tiyin') then
      raise exception 'Неизвестный ключ «%» в ответе модели', v_key using errcode = '22023';
    end if;
  end loop;

  if p ? 'goals' and jsonb_typeof(p -> 'goals') <> 'array' then
    raise exception '«goals» должен быть массивом' using errcode = '22023';
  end if;
  if p ? 'soap' and jsonb_typeof(p -> 'soap') <> 'object' then
    raise exception '«soap» должен быть объектом' using errcode = '22023';
  end if;

  select * into v_event from public.events
   where id = p_event_id and type = 'lesson.voice_received'
     and processed_at is null and claimed_at is not null;
  if not found then
    raise exception 'Событие не найдено или уже обработано' using errcode = '42704';
  end if;

  select * into v_request from public.lesson_voice_requests
   where id = (v_event.payload ->> 'voice_request_id')::uuid;
  if not found then
    raise exception 'Запрос диктовки не найден' using errcode = '42704';
  end if;
  if v_request.center_id <> v_event.center_id then
    raise exception 'Центр события и запроса не совпадают' using errcode = '42501';
  end if;
  -- Р8: проверяется свежесть диктовки, а не токена.
  if v_request.consumed_at is null or v_request.consumed_at < now() - interval '24 hours' then
    raise exception 'Диктовка слишком старая' using errcode = '22023';
  end if;

  -- Р7: перепроверяется то, что относится к данным, а не к сессии.
  if not exists (
    select 1 from public.students s
     where s.id = v_request.student_id and s.deleted_at is null
  ) then
    raise exception 'Ребёнок архивирован' using errcode = '42704';
  end if;

  -- На ветке дополнения существующего черновика триггер состава не
  -- срабатывает: он повешен на update of lesson_id, student_id (0036).
  -- Без этой проверки заметка по отменённому занятию дополнялась бы молча.
  if not exists (
    select 1 from public.lessons l
     where l.id = v_request.lesson_id and l.deleted_at is null and l.status <> 'cancelled'
  ) then
    raise exception 'Занятие отменено или удалено' using errcode = '42704';
  end if;

  select * into v_note from public.lesson_notes
   where lesson_id = v_request.lesson_id and student_id = v_request.student_id
     and center_id = v_request.center_id and deleted_at is null;

  if found then
    if v_note.status = 'approved' then
      raise exception 'Заметка уже утверждена' using errcode = '23514';
    end if;
    -- Повтор того же события ничего не переписывает: возвращаем тот же id.
    -- В3: та же форма ответа, что у обычной ветки. Иначе n8n, повторивший
    -- событие после падения на узле отправки, получит ответ без chat_id и
    -- не сможет сказать специалисту, что черновик готов.
    if v_note.conduct_key = v_request.id then
      return jsonb_build_object(
        'note_id',          v_note.id,
        'student_id',       v_request.student_id,
        'chat_id',          v_request.chat_id,
        'progress_written', 0,
        'progress_skipped', '[]'::jsonb,
        'repeat',           true);
    end if;
    -- Черновик из другого голосового не затираем молча (Р6).
    if v_note.source = 'voice' then
      raise exception 'Черновик по этому ребёнку уже готов — откройте занятие, чтобы поправить'
        using errcode = '23505';
    end if;

    -- Начатый руками черновик голос дополняет, а не затирает.
    update public.lesson_notes
       set conduct_key    = v_request.id,
           soap           = case when p ? 'soap' and coalesce(soap, '{}'::jsonb) = '{}'::jsonb
                                 then p -> 'soap' else soap end,
           parent_summary = coalesce(parent_summary, p ->> 'parent_summary'),
           raw_transcript = coalesce(raw_transcript, p ->> 'raw_transcript'),
           model          = coalesce(model, p ->> 'model'),
           tokens_in      = coalesce(tokens_in, (p ->> 'tokens_in')::integer),
           tokens_out     = coalesce(tokens_out, (p ->> 'tokens_out')::integer),
           cost_tiyin     = coalesce(cost_tiyin, (p ->> 'cost_tiyin')::integer)
     where id = v_note.id;
    v_note_id := v_note.id;
  else
    -- Р2: автор — заказчик диктовки, иначе он не утвердит собственный черновик.
    insert into public.lesson_notes
      (center_id, lesson_id, student_id, teacher_id, created_by,
       raw_transcript, soap, parent_summary, source, conduct_key,
       model, tokens_in, tokens_out, cost_tiyin)
    values
      (v_request.center_id, v_request.lesson_id, v_request.student_id,
       v_request.teacher_id, v_request.requested_by,
       p ->> 'raw_transcript', coalesce(p -> 'soap', '{}'::jsonb), p ->> 'parent_summary',
       'voice', v_request.id,
       p ->> 'model', round((p ->> 'tokens_in')::numeric)::integer,
       round((p ->> 'tokens_out')::numeric)::integer,
       round((p ->> 'cost_tiyin')::numeric)::integer)
    returning id into v_note_id;
  end if;

  -- Б1: предложения, а не goal_progress. В витрину прогресса они попадут
  -- только из approve_lesson_note, то есть после человека.
  for v_item in select * from jsonb_array_elements(coalesce(p -> 'goals', '[]'::jsonb)) loop
    v_inserted := null;

    -- Кривой ответ модели — это пропущенная цель, а не потерянная заметка.
    -- Расшифровка и резюме уже оплачены; ронять их из-за «score: 7.5» или
    -- выдуманного идентификатора нельзя (В8). Отдельно стоит только цель
    -- чужого ребёнка — там речь о смешении карт детей.
    if jsonb_typeof(v_item -> 'score') <> 'number'
       or (v_item ->> 'goal_id') is null then
      v_skipped := v_skipped || jsonb_build_object(
        'goal_id', v_item ->> 'goal_id', 'reason', 'ответ модели не разобран');
      continue;
    end if;

    v_score := round((v_item ->> 'score')::numeric)::integer;
    if v_score < 0 or v_score > 100 then
      v_skipped := v_skipped || jsonb_build_object(
        'goal_id', v_item ->> 'goal_id', 'reason', 'оценка вне диапазона');
      continue;
    end if;

    -- Р5: цель обязана принадлежать тому же ребёнку. На групповом занятии
    -- сосед — законный участник, и триггер состава его бы пропустил.
    select * into v_goal from public.goals
     where id = (v_item ->> 'goal_id')::uuid
       and center_id = v_request.center_id
       and deleted_at is null;

    if found and v_goal.student_id <> v_request.student_id then
      raise exception 'Оценка по цели другого ребёнка' using errcode = '42704';
    end if;
    if not found then
      v_skipped := v_skipped || jsonb_build_object(
        'goal_id', v_item ->> 'goal_id', 'reason', 'цель не найдена');
      continue;
    end if;

    insert into public.lesson_note_goal_scores (center_id, note_id, goal_id, score, note)
    values (v_request.center_id, v_note_id, v_goal.id, v_score, v_item ->> 'note')
    on conflict (note_id, goal_id) do nothing
    returning id into v_inserted;

    if v_inserted is null then
      v_skipped := v_skipped || jsonb_build_object(
        'goal_id', v_goal.id, 'title', v_goal.title, 'reason', 'уже предложена');
    else
      v_written := v_written + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'note_id',          v_note_id,
    'student_id',       v_request.student_id,
    'chat_id',          v_request.chat_id,
    'progress_written', v_written,
    'progress_skipped', v_skipped,
    'repeat',           false
  );
end;
$$;

comment on function public.ai_write_lesson_note(bigint, jsonb) is
  'Черновик из голосового. Всё существенное — из строки запроса, а не из параметров: подменить занятие или ребёнка нечем (Р3). Возвращает пропущенные цели, чтобы специалисту сказали, что записалось не всё (Р6).';

revoke all on function public.ai_write_lesson_note(bigint, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.ai_write_lesson_note(bigint, jsonb) to bot_worker;
