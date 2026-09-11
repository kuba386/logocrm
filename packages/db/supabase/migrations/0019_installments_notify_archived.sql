-- =============================================================================
-- 0019_installments_notify_archived.sql — installments_notify: архив ученика
--
-- 0018 влита с красным db-джобом (ассерт 36 теста 0018): installments_notify
-- отсекала архивных учеников по students.deleted_at, а archive_student
-- (0011) ставит students.status = 'archived' и deleted_at не трогает —
-- уведомление installment.due уходило родителю ребёнка, которого в
-- интерфейсе уже нет. Миграция после мержа неизменяема — правка здесь:
-- тело функции из 0018 дословно плюс фильтр по status в обоих проходах.
-- =============================================================================

create or replace function public.installments_notify()
  returns table (due_count integer, overdue_count integer)
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_due     integer := 0;
  v_overdue integer := 0;
  r         record;
begin
  if auth.uid() is not null then
    raise exception 'Недостаточно прав' using errcode = '42501';
  end if;

  for r in
    update public.installments i
       set due_notified_at = now()
      from public.installments_view v
      join public.subscriptions s on s.id = v.subscription_id
      join public.students st on st.id = v.student_id
     where i.id = v.id
       and v.state = 'due'
       and i.due_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       -- 0019: архив ученика — status = 'archived' (archive_student, 0011),
       -- не deleted_at.
       and st.deleted_at is null and st.status <> 'archived'
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.due',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_due := v_due + 1;
  end loop;

  for r in
    update public.installments i
       set overdue_notified_at = now()
      from public.installments_view v
      join public.subscriptions s on s.id = v.subscription_id
      join public.students st on st.id = v.student_id
     where i.id = v.id
       and v.state = 'overdue'
       and i.overdue_notified_at is null
       and s.deleted_at is null and s.status <> 'cancelled'
       and st.deleted_at is null and st.status <> 'archived'  -- 0019
     returning i.id, i.center_id, i.subscription_id, i.student_id, i.payer_id,
               i.seq, i.due_date, i.amount_tiyin
  loop
    perform public.emit_event_unchecked('installment.overdue',
      jsonb_build_object(
        'center_id', r.center_id, 'installment_id', r.id,
        'subscription_id', r.subscription_id, 'student_id', r.student_id,
        'payer_id', r.payer_id, 'seq', r.seq, 'due_date', r.due_date,
        'amount_tiyin', r.amount_tiyin
      ),
      r.center_id);
    v_overdue := v_overdue + 1;
  end loop;

  return query select v_due, v_overdue;
end;
$$;

-- create or replace сохраняет ACL: функция закрыта для public/anon/
-- authenticated с 0018 (закрытый список 0007). Повторный revoke — на
-- случай, если 0018 применялась не до конца.
revoke all on function public.installments_notify() from public, anon, authenticated;
