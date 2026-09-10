-- =============================================================================
-- 0012_archive_catalogs.sql — архив для attendance_statuses и subscription_types
--
--   1. Колоночные гранты сужены: deleted_at (и у статусов — is_default)
--      пишутся только через RPC, не прямым PATCH.
--   2. CHECK на attendance_statuses: архивный статус не может быть default —
--      синхронно ловит и архив живого default (deleted_at меняется, is_default
--      остаётся true), и INSERT с обоими полями разом.
--   3. Отложенный constraint trigger — вторая половина инварианта. Партиал-
--      индекс attendance_statuses_center_default_idx (0008) синхронно не
--      пускает ВТОРОЙ default; CHECK не пускает default+deleted_at на одной
--      строке. Ни то, ни другое не ловит НУЛЕВОЙ default — вот для этого
--      случая и нужна отложенная проверка на COMMIT: она видит финальное
--      состояние после обеих записей set_default_attendance_status, а не
--      промежуточный ноль между «снять со старого» и «поставить новому».
--      Не self-referential — без pg_trigger_depth() и его сессионного счётчика.
--   4. attendance_statuses_read_all — без deleted_at is null: специалист и
--      родитель должны видеть имя/цвет архивного статуса в истории посещений.
--   5. subscription_types_read_archived — вторая, узкая select-политика:
--      архивные строки видит только owner/admin, tenant_admin не трогаем.
--   6. RPC: set_default_attendance_status, archive/restore для обеих таблиц.
--
-- Долг с этапа 4 (справочники без макета): кнопок архива не было, потому
-- что прямой update deleted_at не проходил tenant_admin (PostgREST
-- заворачивает update в `... returning *`, а using(deleted_at is null) не
-- пропускает уже обновлённую строку). Разбор со стороны архитектора занял
-- два раунда — первый принял self-referential trigger с pg_trigger_depth(),
-- второй указал, что счётчик глобален по сессии и будущий триггер на этой
-- таблице тихо его обманет; здесь — версия без вложенного update вовсе.
-- =============================================================================


-- 1. Колоночные гранты -----------------------------------------------------------

revoke update on public.attendance_statuses, public.subscription_types from authenticated;

grant update (code, name, color, deducts_lesson, pays_teacher, counts_absence, notify_parent, sort)
  on public.attendance_statuses to authenticated;

grant update (name, service_id, kind, lessons_count, period_days, price_tiyin, is_active)
  on public.subscription_types to authenticated;


-- 2. CHECK: архивный статус не может остаться default -----------------------------

-- Закрывает прямой POST с одновременным is_default=true и deleted_at
-- заполненным — колоночный грант на insert у attendance_statuses не сужен
-- (см. 0008), значит этот путь не защищён ничем, кроме этого констрейнта.
alter table public.attendance_statuses
  add constraint attendance_statuses_default_not_deleted
  check (not (is_default and deleted_at is not null));


-- 3. Отложенный constraint trigger: ровно один живой default на центр -------------

create or replace function public.attendance_statuses_check_default()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := coalesce(new.center_id, old.center_id);
  v_count  integer;
begin
  select count(*) into v_count
    from public.attendance_statuses
   where center_id = v_center and is_default and deleted_at is null;

  if v_count <> 1 then
    raise exception 'В центре должен быть ровно один статус посещения по умолчанию' using errcode = '22023';
  end if;

  return null;
end;
$$;

drop trigger if exists attendance_statuses_check_default on public.attendance_statuses;
create constraint trigger attendance_statuses_check_default
  after insert or update of is_default, deleted_at on public.attendance_statuses
  deferrable initially deferred
  for each row execute function public.attendance_statuses_check_default();


-- 4. attendance_statuses_read_all — архивные видит весь центр ---------------------

-- Отметки прошлого никуда не делись — их статус обязан остаться читаемым и
-- специалисту, и родителю, иначе история посещений красит «—» зелёным.
drop policy if exists attendance_statuses_read_all on public.attendance_statuses;
create policy attendance_statuses_read_all on public.attendance_statuses
  for select to authenticated
  using (center_id = public.current_center());


-- 5. subscription_types_read_archived — узкая политика поверх tenant_admin --------

-- tenant_admin (apply_tenant_rls) остаётся как есть: using(deleted_at is
-- null), только owner/admin. Эта политика добавляет archived-строки той же
-- аудитории — Postgres берёт OR по всем permissive-политикам одной команды.
drop policy if exists subscription_types_read_archived on public.subscription_types;
create policy subscription_types_read_archived on public.subscription_types
  for select to authenticated
  using (
    center_id = public.current_center()
    and deleted_at is not null
    and coalesce(public.my_role(), '') in ('owner', 'admin')
  );


-- 6. RPC ---------------------------------------------------------------------------

create or replace function public.set_default_attendance_status(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.attendance_statuses
     set is_default = false
   where center_id = v_center and is_default and deleted_at is null and id <> p_id;

  -- Узкая гонка: параллельный set_default_attendance_status для другого id
  -- уже мог успеть снять старый default и поставить его себе первым — тогда
  -- этот update столкнётся с attendance_statuses_center_default_idx (0008)
  -- синхронно, до commit. Ловим явно, иначе пользователь увидит нативный
  -- английский текст unique_violation вместо русского.
  begin
    update public.attendance_statuses
       set is_default = true
     where id = p_id and center_id = v_center and deleted_at is null;
  exception
    when unique_violation then
      raise exception 'Статус по умолчанию уже назначили параллельно — обновите страницу и повторите'
        using errcode = '22023';
  end;

  if not found then
    raise exception 'Статус не найден' using errcode = '42704';
  end if;

  perform public.emit_event('attendance_status.default_changed',
    jsonb_build_object('center_id', v_center, 'status_id', p_id), v_center);
end;
$$;

create or replace function public.archive_attendance_status(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  -- Архив действующего default меняет deleted_at на строке, где is_default
  -- ещё true — CHECK attendance_statuses_default_not_deleted откажет тут же
  -- (23514), синхронно. Отдельной проверки не нужно.
  update public.attendance_statuses
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Статус не найден' using errcode = '42704';
  end if;

  perform public.emit_event('attendance_status.archived',
    jsonb_build_object('center_id', v_center, 'status_id', p_id), v_center);
end;
$$;

create or replace function public.restore_attendance_status(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
  v_code   text;
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  select code into v_code
    from public.attendance_statuses
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Статус не найден в архиве' using errcode = '42704';
  end if;

  begin
    update public.attendance_statuses
       set deleted_at = null
     where id = p_id and center_id = v_center and deleted_at is not null;
  exception
    when unique_violation then
      raise exception 'Код «%» уже занят другим статусом — переименуйте перед восстановлением', v_code
        using errcode = '22023';
  end;

  perform public.emit_event('attendance_status.restored',
    jsonb_build_object('center_id', v_center, 'status_id', p_id), v_center);
end;
$$;

create or replace function public.archive_subscription_type(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.subscription_types
     set deleted_at = now()
   where id = p_id and center_id = v_center and deleted_at is null;

  if not found then
    raise exception 'Тип абонемента не найден' using errcode = '42704';
  end if;

  perform public.emit_event('subscription_type.archived',
    jsonb_build_object('center_id', v_center, 'subscription_type_id', p_id), v_center);
end;
$$;

create or replace function public.restore_subscription_type(p_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := public.current_center();
begin
  if coalesce(public.my_role(), '') not in ('owner', 'admin') then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  update public.subscription_types
     set deleted_at = null
   where id = p_id and center_id = v_center and deleted_at is not null;

  if not found then
    raise exception 'Тип абонемента не найден в архиве' using errcode = '42704';
  end if;

  perform public.emit_event('subscription_type.restored',
    jsonb_build_object('center_id', v_center, 'subscription_type_id', p_id), v_center);
end;
$$;


-- Гранты: триггерная функция закрыта совсем (вызывается только Postgres'ом
-- изнутри trigger-механизма), пять RPC — только authenticated.
revoke execute on function
  public.attendance_statuses_check_default(),
  public.set_default_attendance_status(uuid),
  public.archive_attendance_status(uuid),
  public.restore_attendance_status(uuid),
  public.archive_subscription_type(uuid),
  public.restore_subscription_type(uuid)
  from public, anon, authenticated;

grant execute on function
  public.set_default_attendance_status(uuid),
  public.archive_attendance_status(uuid),
  public.restore_attendance_status(uuid),
  public.archive_subscription_type(uuid),
  public.restore_subscription_type(uuid)
  to authenticated;
