-- =============================================================================
-- 0085_goals_from_diagnostic.sql — цели из диагностики, след печати речевой карты
--
-- Этап 9 (docs/Roadmap/stages.md). Решения владельца 2.10.2026: стартовый
-- этап для «искажение», «отсутствие», «замена» — «Постановка» (код 'setting',
-- 0036); подпись на карте не нужна. Цели по областям (лексика и др.) не в
-- этом этапе: у цели этап обязателен, а goal_stages — этапы работы над звуком.
--
-- Ревью плана — architect:
--   Р1. Инвариант «одна активная цель на звук и этап» — частичный уникальный
--       индекс, не проверка в функции. Нормализация lower(btrim(sound)) — та
--       же, что в функциях ниже. Цели без звука (по областям) и пустой звук в
--       индекс не попадают намеренно; paused/achieved/удалённые — тоже.
--       Дублей на staging и prod до индекса нет (проверено 2.10.2026).
--       Индекс задевает и старые пути — set_goal_status (снять с паузы) и
--       update_goal (смена звука/этапа) — общий текст 23505 в errors.ts.
--   Р2. goal_suggestions — security definer с явным фильтром центра (RLS
--       обходится) и гейтом роли: owner/admin или clinical_teacher_sees.
--       Архивный ученик и удалённая диагностика — 42704. Нет живого этапа
--       'setting' в центре — пустой набор.
--   Р3. Цель по тому же звуку на ДРУГОМ этапе или на паузе не блокирует
--       предложение, но отдаётся (existing_stage_title/existing_status):
--       иначе повторная диагностика предлагала бы регресс к постановке молча.
--       already_active — только точное совпадение (звук, 'setting', active).
--   Р4. create_goals_from_diagnostic пересчитывает предложения (ключи от
--       клиента — только выбор), создаёт через create_goal (0038, его
--       проверки не дублируем; auth.uid/my_role/current_center берутся из
--       JWT и при вложенном вызове те же). unique_violation на отдельном
--       звуке (параллельный вызов) — пропуск звука, а не откат всей пачки.
--       Read-only центр: create_goal упрётся в guard goals — PT402.
--   Р5. След печати — событие при открытии печатного вида на сервере
--       (student.speech_card_opened), а не по кнопке: печать через меню
--       браузера иначе прошла бы мимо журнала. events вне guard — работает и
--       в read-only.
-- =============================================================================


-- 1. Одна активная цель на звук и этап ------------------------------------------------------------------

create unique index if not exists goals_one_active_per_sound_stage
  on public.goals (student_id, lower(btrim(sound)), stage_id)
  where status = 'active' and deleted_at is null and sound is not null and btrim(sound) <> '';


-- 2. Предложения целей по последней диагностике ------------------------------------------------------------

create or replace function public.goal_suggestions(p_diagnostic_id uuid)
  returns table (
    sound                text,
    sound_status         text,
    stage_id             uuid,
    stage_title          text,
    title                text,
    already_active       boolean,
    existing_stage_title text,
    existing_status      text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_student uuid;
  v_sounds  jsonb;
  v_stage   public.goal_stages;
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  select d.student_id, d.sounds into v_student, v_sounds
    from public.diagnostics d
    join public.students s on s.id = d.student_id and s.center_id = d.center_id and s.deleted_at is null
   where d.id = p_diagnostic_id and d.center_id = v_center and d.deleted_at is null;
  if v_student is null then
    raise exception 'Диагностика не найдена' using errcode = '42704';
  end if;

  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_student)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select * into v_stage
    from public.goal_stages gs
   where gs.center_id = v_center and gs.code = 'setting' and gs.deleted_at is null;
  if not found then
    return;
  end if;

  return query
    with marks as (
      -- «р» и «Р » в одной карте — один звук; карта не объект — пусто, не 22023.
      select distinct on (lower(btrim(e.key))) lower(btrim(e.key)) as snd, e.value as status
        from jsonb_each_text(
               case when jsonb_typeof(v_sounds) = 'object' then v_sounds else '{}'::jsonb end
             ) e
       where e.value in ('искажение', 'отсутствие', 'замена')
         and btrim(e.key) <> ''
       order by lower(btrim(e.key)), e.key
    )
    select m.snd,
           m.status,
           v_stage.id,
           v_stage.title,
           'Звук ' || m.snd || ': ' || lower(v_stage.title),
           exists (
             select 1 from public.goals g
              where g.student_id = v_student and g.center_id = v_center and g.deleted_at is null
                and g.status = 'active' and g.stage_id = v_stage.id
                and lower(btrim(g.sound)) = m.snd
           ),
           x.stage_title,
           x.status
      from marks m
      left join lateral (
        -- Любая живая цель по звуку (кроме достигнутых): активная раньше паузы.
        select gs.title as stage_title, g.status
          from public.goals g
          join public.goal_stages gs on gs.id = g.stage_id
         where g.student_id = v_student and g.center_id = v_center and g.deleted_at is null
           and g.status in ('active', 'paused') and lower(btrim(g.sound)) = m.snd
         order by (g.status = 'active') desc, gs.sort desc
         limit 1
      ) x on true
     order by coalesce(array_position(array['р','л','ш','ж','с','з','ц','ч','щ'], m.snd), 100), m.snd;
end;
$$;

comment on function public.goal_suggestions(uuid) is
  'Цели по нарушенным звукам диагностики (0085, этап 9): «искажение», «отсутствие», «замена» → этап «Постановка» центра. already_active — точно такая цель уже активна; existing_* — живая цель по звуку на любом этапе (предупреждение). owner/admin или специалист ученика.';

revoke all on function public.goal_suggestions(uuid) from public, anon, service_role;
grant execute on function public.goal_suggestions(uuid) to authenticated;


-- 3. Создать выбранные --------------------------------------------------------------------------------------

create or replace function public.create_goals_from_diagnostic(p_diagnostic_id uuid, p_sounds text[])
  returns integer
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center  uuid := public.current_center();
  v_role    text := coalesce(public.my_role(), '');
  v_student uuid;
  v_wanted  text[];
  v_sugg    jsonb;
  v_item    jsonb;
  v_sound   text;
  v_created integer := 0;
begin
  -- Свой гейт, а не только goal_suggestions: переиздание той функции не
  -- должно молча снять защиту с записи (ревью написанного SQL).
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;
  select d.student_id into v_student
    from public.diagnostics d
    join public.students s on s.id = d.student_id and s.center_id = d.center_id and s.deleted_at is null
   where d.id = p_diagnostic_id and d.center_id = v_center and d.deleted_at is null;
  if v_student is null then
    raise exception 'Диагностика не найдена' using errcode = '42704';
  end if;
  if not (v_role in ('owner', 'admin') or public.clinical_teacher_sees(v_student)) then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select array_agg(distinct lower(btrim(s)))
    into v_wanted
    from unnest(coalesce(p_sounds, '{}'::text[])) s
   where btrim(s) <> '';
  if v_wanted is null then
    raise exception 'Отметьте хотя бы одну цель' using errcode = '22023';
  end if;

  select coalesce(jsonb_object_agg(g.sound, to_jsonb(g)), '{}'::jsonb)
    into v_sugg
    from public.goal_suggestions(p_diagnostic_id) g;

  foreach v_sound in array v_wanted loop
    if not v_sugg ? v_sound then
      raise exception 'Звук «%» не предложен этой диагностикой', v_sound using errcode = '22023';
    end if;
  end loop;

  foreach v_sound in array v_wanted loop
    v_item := v_sugg -> v_sound;
    continue when (v_item ->> 'already_active')::boolean;
    begin
      perform public.create_goal(
        v_student, (v_item ->> 'stage_id')::uuid, v_item ->> 'title', 'звукопроизношение', v_sound, null
      );
      v_created := v_created + 1;
    exception when unique_violation then
      -- Параллельный вызов успел создать эту цель — пропуск, не откат пачки.
      null;
    end;
  end loop;

  return v_created;
end;
$$;

comment on function public.create_goals_from_diagnostic(uuid, text[]) is
  'Создаёт выбранные цели из goal_suggestions (0085, этап 9) через create_goal. Звук не из предложений — 22023; уже активная — пропуск; гонка (23505 на звуке) — пропуск. Возвращает число созданных.';

revoke all on function public.create_goals_from_diagnostic(uuid, text[]) from public, anon, service_role;
grant execute on function public.create_goals_from_diagnostic(uuid, text[]) to authenticated;


-- 4. След печати речевой карты ------------------------------------------------------------------------------

create or replace function public.log_speech_card_opened(p_student_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_role   text := coalesce(public.my_role(), '');
begin
  if auth.uid() is null or v_center is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
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

  perform public.emit_event(
    'student.speech_card_opened',
    jsonb_build_object('student_id', p_student_id, 'by', auth.uid(), 'role', nullif(v_role, '')),
    v_center
  );
end;
$$;

comment on function public.log_speech_card_opened(uuid) is
  'След открытия речевой карты для печати (0085, этап 9): событие student.speech_card_opened без адресата, как report.exported (0058). Зовёт сервер при рендере печатного вида, не кнопка.';

revoke all on function public.log_speech_card_opened(uuid) from public, anon, service_role;
grant execute on function public.log_speech_card_opened(uuid) to authenticated;
