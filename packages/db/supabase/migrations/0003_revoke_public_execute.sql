-- =============================================================================
-- 0003_revoke_public_execute.sql — снятие дефолтного GRANT EXECUTE TO PUBLIC
--
-- 0002 снял гранты с роли anon, но этого мало: Postgres выдаёт EXECUTE роли
-- PUBLIC на каждую новую функцию, а anon в PUBLIC входит. Пока PUBLIC-грант
-- на месте, revoke от anon ничего не меняет.
--
-- После этой миграции право вызова остаётся только у тех, кому оно выдано
-- явно в 0001 (роль authenticated) и у service_role.
--
-- audit_trigger, slugify и DDL-процедуры не выдаются никому: триггерную функцию
-- запускает сам Postgres (грант при срабатывании не проверяется), slug строит
-- create_center, а процедуры вызываются только из миграций.
-- =============================================================================

revoke execute on function public.current_center()              from public;
revoke execute on function public.my_role()                     from public;
revoke execute on function public.my_teacher_id()               from public;
revoke execute on function public.my_payer_id()                 from public;
revoke execute on function public.role_in(uuid)                 from public;
revoke execute on function public.is_member(uuid)               from public;
revoke execute on function public.has_feature(text)             from public;
revoke execute on function public.switch_center(uuid)           from public;
revoke execute on function public.create_center(text, text)     from public;
revoke execute on function public.emit_event(text, jsonb, uuid) from public;
revoke execute on function public.slugify(text)                 from public;
revoke execute on function public.audit_trigger()               from public;

revoke execute on procedure public.apply_tenant_rls(text) from public;
revoke execute on procedure public.apply_audit(text)      from public;
