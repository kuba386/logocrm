-- =============================================================================
-- 0046_goal_progress_trend.sql — тренд по цели за последние занятия
--
-- Владелец просил аналитику по уже записанным public.goal_progress.score
-- без LLM: застой/регресс/рост видны из чисел, которые уже в базе,
-- генеративный текст тут ни к чему и только добавляет риск галлюцинации.
--
-- Решения (обсуждены с владельцем и architect-субагентом до написания):
--
--   Р1. Окно — последние 3 занятия по цели, сортировка
--       (date, created_at, id) desc. Третий ключ обязателен: без него
--       порядок недетерминирован, когда complete_lesson (0039) пишет
--       несколько goal_progress одной транзакцией с одинаковым date и
--       created_at — два одинаковых запроса давали бы разный trend на
--       одних и тех же данных.
--
--   Р2. Правила взаимоисключающие, приоритет явный и проверяется в этом
--       порядке: регресс → застой → рост → 'stable'. Регресс — первым:
--       упущенное падение важнее отчёта о росте. На триплете
--       s3=0, s2=30, s1=20 (последняя оценка ниже предыдущей на 10, но
--       выше самой старой на 20) при проверке «что первое совпало» это
--       обязано дать 'regress', не 'growth' — без явного порядка это
--       решал бы порядок веток в case, то есть implementation detail,
--       а не спека.
--
--   Р3. null — только когда записей меньше 3 («мало данных»), никогда
--       не «есть данные, но паттерн не подошёл под правило» — для этого
--       случая есть отдельное явное значение 'stable'. Тот же класс
--       ошибки, что student_balance.lessons_left (null = и «безлимит», и
--       «нет абонемента» — разбирались дважды за сессию, не повторять).
--
--   Р4. Видимость — только персоналу (owner/admin/teacher), родителю
--       всегда null. last_score родитель и так уже видит через этот же
--       RPC, а trend раскрывает отношение между тремя оценками — то
--       есть больше истории, чем одно число. Плюс родителю отдельно
--       показывается динамика за период в student_goal_dynamics_brief
--       (0043, месячный отчёт, снимок) — два разных окна одновременно
--       на экране родителя («застой» на панели целей и «+15 за месяц»
--       в отчёте) путали бы больше, чем помогали. Можно расширить
--       позже, когда обкатается у специалистов.
--
--   Р5. create or replace function не может добавить колонку в
--       returns table (42P13, cannot change return type) — drop +
--       create, с переизданием revoke/grant/comment: у dropped функции
--       Postgres выдаёт EXECUTE роли PUBLIC, Supabase — anon и
--       authenticated, снимать нужно оба явно (тот же приём, что 0035,
--       0015, 0029 при смене состава колонок).
--
-- last_score и trend теперь считаются одним lateral-подзапросом вместо
-- двух независимых — иначе при разной сортировке рядом на экране могли
-- бы оказаться last_score от одной записи и trend, посчитанный по
-- другому окну.

drop function if exists public.student_goals_brief(uuid);

create function public.student_goals_brief(p_student_id uuid)
  returns table (
    id          uuid,
    title       text,
    area        text,
    sound       text,
    stage_title text,
    stage_sort  integer,
    status      text,
    target_date date,
    last_score  integer,
    trend       text
  )
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
begin
  if not public.clinical_visible_to_caller(p_student_id) then
    return;
  end if;

  return query
    select
      g.id, g.title, g.area, g.sound, st.title, st.sort, g.status, g.target_date,
      gp.s1,
      case
        when coalesce(public.my_role(), '') = 'parent' then null
        when gp.n is null or gp.n < 3 then null
        when gp.s1 - gp.s2 <= -10 then 'regress'
        when gp.max_score - gp.min_score <= 5 then 'stagnant'
        when gp.s1 - gp.s3 >= 10 then 'growth'
        else 'stable'
      end
    from public.goals g
    join public.goal_stages st on st.id = g.stage_id
    left join lateral (
      select
        count(*)::int                                as n,
        max(x.score) filter (where x.rn = 1)          as s1,
        max(x.score) filter (where x.rn = 2)          as s2,
        max(x.score) filter (where x.rn = 3)          as s3,
        max(x.score)                                  as max_score,
        min(x.score)                                  as min_score
      from (
        select p.score,
               row_number() over (order by p.date desc, p.created_at desc, p.id desc) as rn
          from public.goal_progress p
         where p.goal_id = g.id
           and p.center_id = g.center_id
           and p.deleted_at is null
         order by p.date desc, p.created_at desc, p.id desc
         limit 3
      ) x
    ) gp on true
    where g.student_id = p_student_id
      and g.center_id = public.current_center()
      and g.deleted_at is null
    order by st.sort, g.created_at;
end;
$$;

comment on function public.student_goals_brief(uuid) is
  'Цели ребёнка с последней оценкой и трендом за 3 занятия (регресс/застой/рост/stable, null — данных меньше 3). trend только для персонала — родителю всегда null (Р4). Колонки note из goal_progress здесь нет: это внутренняя пометка специалиста, тот же класс, что payers.notes у бухгалтера в 0031.';

revoke all on function public.student_goals_brief(uuid) from public, anon;
grant execute on function public.student_goals_brief(uuid) to authenticated;
