-- =============================================================================
-- 0083_trial_limit_contact_phone.sql — контакт платформы в отказе второго trial
--
-- Решение владельца платформы (1.10.2026): центрам для связи — телефон
-- 0707 001 107, не почта. Почта была зашита в текст отказа
-- assert_one_trial_center (0052 Р9); веб до этой миграции подменял его в
-- apps/web/lib/errors.ts.
--
-- Ревью плана — architect:
--   Р1. Последнее определение — 0052 (других нет); тело перенесено посимвольно,
--       отличаются только два текста raise. Сигнатура та же: create or replace
--       сохраняет владельца, ACL и security definer, триггер
--       memberships_one_trial_per_owner() находит функцию по имени — его не
--       пересоздаём. Подсчёт не меняется: членства не архивируются
--       (deleted_at у memberships нет), считается c.deleted_at центра.
--   Р2. Телефон — в обеих ветках: p_self (сам открывает второй trial) и
--       повышение до owner участника со своим trial (это видит owner/admin
--       центра, раньше без контакта).
--   Р3. Почта в 0049 (сид platform_admins) — идентификация администратора
--       платформы, не текст для центров: не трогать, иначе владелец
--       платформы потеряет права.
--   Р4. revoke повторён по конвенции, grant не добавляется: функцию зовёт
--       только триггер.
--   Р5. Подмена текста в errors.ts остаётся до deploy-prod (веб катится из
--       main сразу, миграции прода — вручную); убрать отдельной задачей
--       после выката, иначе следующая правка текста в SQL молча перекроется.
-- =============================================================================

create or replace function public.assert_one_trial_center(p_user_id uuid, p_self boolean)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('trial_owner:' || p_user_id::text, 0));

  -- Trial-центры, закрытые меньше 90 дней назад, считаются: иначе
  -- «закрыл — открыл новый» даёт бесконечный trial.
  if (select count(*)
        from public.centers c
        join public.memberships m on m.center_id = c.id and m.role = 'owner'
       where m.user_id = p_user_id
         and c.plan = 'trial'
         and (c.deleted_at is null or c.deleted_at > now() - interval '90 days')) > 1
  then
    if p_self then
      raise exception 'У вас уже есть центр на пробном периоде. Второй центр открывает администратор платформы — позвоните или напишите: 0707 001 107.'
        using errcode = '23514';
    end if;
    raise exception 'У этого участника уже есть свой центр на пробном периоде — сделать его владельцем второго trial-центра может только администратор платформы: 0707 001 107.'
      using errcode = '23514';
  end if;
end;
$$;

revoke all on function public.assert_one_trial_center(uuid, boolean) from public, anon, authenticated, service_role;
