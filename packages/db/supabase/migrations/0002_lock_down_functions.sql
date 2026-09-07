-- =============================================================================
-- 0002_lock_down_functions.sql — закрытие функций от anon и защита emit_event
--
-- Найдено линтером Supabase после применения 0001:
--
--   1. Supabase раздаёт EXECUTE ролям anon/authenticated через default privileges
--      на все функции в public. `revoke ... from public` в 0001 эти явные гранты
--      не снимал, поэтому security definer-функции были доступны анониму.
--
--   2. emit_event принимал p_center_id без проверки: аноним мог писать события
--      в outbox любого центра, а пользователь центра А — в центр Б. Это пробой
--      изоляции тенантов (ADR-002), а не косметика.
--
--   3. apply_tenant_rls / apply_audit были объявлены без set search_path.
-- =============================================================================


-- 1. emit_event: требуем авторизацию и членство в центре ----------------------

create or replace function public.emit_event(
  p_type      text,
  p_payload   jsonb default '{}'::jsonb,
  p_center_id uuid default null
)
  returns bigint
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_center uuid := coalesce(p_center_id, public.current_center());
  v_id     bigint;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация' using errcode = '42501';
  end if;

  if v_center is null then
    raise exception 'emit_event: не определён center_id' using errcode = '22004';
  end if;

  -- p_center_id существует ради вызовов изнутри create_center, когда нового
  -- center_id ещё нет в JWT. Членство к этому моменту уже создано, поэтому
  -- проверка проходит — и одновременно закрывает запись в чужой центр.
  if public.role_in(v_center) is null then
    raise exception 'Нет доступа к центру %', v_center using errcode = '42501';
  end if;

  insert into public.events (center_id, type, payload)
  values (v_center, p_type, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;

  return v_id;
end;
$$;


-- 2. search_path у DDL-процедур ----------------------------------------------

create or replace procedure public.apply_tenant_rls(tbl text)
  language plpgsql
  set search_path = ''
as $$
begin
  execute format('alter table public.%I enable row level security', tbl);
  execute format('drop policy if exists tenant_admin on public.%I', tbl);
  execute format(
    'create policy tenant_admin on public.%I for all to authenticated
       using (center_id = public.current_center()
              and public.my_role() in (''owner'', ''admin'')
              and deleted_at is null)
       with check (center_id = public.current_center()
                   and public.my_role() in (''owner'', ''admin''))',
    tbl
  );
end;
$$;

create or replace procedure public.apply_audit(tbl text)
  language plpgsql
  set search_path = ''
as $$
begin
  execute format('drop trigger if exists %I on public.%I', tbl || '_audit', tbl);
  execute format(
    'create trigger %I after insert or update or delete on public.%I
       for each row execute function public.audit_trigger()',
    tbl || '_audit', tbl
  );
end;
$$;


-- 3. Снимаем гранты, выданные Supabase по умолчанию ---------------------------

-- Аноним не должен вызывать ничего из нашего API: любой сценарий начинается
-- с авторизации.
revoke execute on function public.current_center()                    from anon;
revoke execute on function public.my_role()                           from anon;
revoke execute on function public.my_teacher_id()                     from anon;
revoke execute on function public.my_payer_id()                       from anon;
revoke execute on function public.role_in(uuid)                       from anon;
revoke execute on function public.is_member(uuid)                     from anon;
revoke execute on function public.has_feature(text)                   from anon;
revoke execute on function public.switch_center(uuid)                 from anon;
revoke execute on function public.create_center(text, text)           from anon;
revoke execute on function public.emit_event(text, jsonb, uuid)       from anon;
revoke execute on function public.slugify(text)                       from anon;

-- Триггерная функция не предназначена для вызова через REST вообще.
revoke execute on function public.audit_trigger() from anon, authenticated;

-- DDL-процедуры вызываются только миграциями.
revoke execute on procedure public.apply_tenant_rls(text) from anon, authenticated;
revoke execute on procedure public.apply_audit(text)      from anon, authenticated;

-- slugify авторизованным не нужен: slug генерирует create_center.
revoke execute on function public.slugify(text) from authenticated;
