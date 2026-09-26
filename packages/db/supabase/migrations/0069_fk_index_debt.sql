-- =============================================================================
-- 0069_fk_index_debt.sql — два долга, вынесенных из ревью 0066/0067/0068
--
-- Оба пункта записаны в reports/speech-card.md («Что осталось владельцу») и
-- в шапках 0067 (Р5) / 0068 (Р10, Р12) как «долг, отдельная задача». Здесь
-- закрываются целиком, только для тех constraint'ов, что переиздаёт эта
-- миграция, плюс для обеих составных FK на трёх таблицах речевой карты
-- (0066/0067/0068) — критерий объёма, не число из советника (Р3 ниже).
--
--   Р1. Голый `on delete set null` на составном FK (без списка колонок)
--       зануляет ВСЮ пару, включая `center_id not null` — тот же класс
--       ошибки, что чинили 0022 (см. его шапку) и сами 0067/0068 с самого
--       начала. Четыре констрейнта остались непочиненными: diagnostics_
--       teacher_fk, goal_progress_lesson_fk, homework_lesson_fk (0036) и
--       syllable_assessments_teacher_fk (0066). student_fk на syllable_/
--       prosody_/reading_writing_assessments — `on delete cascade`, этого
--       класса ошибки не касается, не трогается.
--       Путь достижим уже сегодня, не только через будущий ADR-012:
--       `delete from centers` (сам owner/admin insert/delete на centers не
--       выдан, но каскад применим руками через service_role/postgres) валит
--       ON DELETE CASCADE в teachers/lessons и упирался ровно в тот 23502,
--       что чинит этот раздел — проверено на реальных dev-данных перед
--       написанием этой миграции. request_center_deletion (0056) сегодня
--       ставит только deleted_at, физическая очистка через 30 дней —
--       ADR-012, вне этого этапа; но забор нужен не «на будущее ADR-012», а
--       уже для ручного/аварийного пути, которым центр можно удалить прямо
--       сейчас.
--       Обе таблицы-родителя (teachers, lessons) — старые, с реальными
--       строками. `drop constraint` — БЕЗ `if exists`: если имя разошлось с
--       ожидаемым, деплой должен упасть громко, а не тихо оставить старую
--       семантику при зелёном CI. Констрейнты уже validated — повторная
--       валидация проверит ровно то же множество строк, сиротам взяться
--       неоткуда; `not valid` + отдельная `validate constraint` здесь не
--       снижает блокировку (CLI применяет файл одной транзакцией) — не
--       нужны.
--       Каскад после этой миграции доходит до полноценного UPDATE дочерней
--       строки (RI SET NULL — не «тихий» no-op), значит поднимает ВСЕ
--       row-триггеры четырёх таблиц, не только очевидные:
--         - clinical_check_lesson_participant (goal_progress/homework, 0036)
--           — выходит по `new.lesson_id is null`, безопасно;
--         - homework_status_transition (0045, before insert or update, без
--           списка колонок) — no-op, потому что SET NULL не меняет status;
--         - *_set_updated_at/moddatetime — сдвигает updated_at дочерней
--           строки. Ожидаемая форма, но у неё есть следствие: update_
--           syllable_assessment/update_reading_writing_assessment сверяют
--           p_expected_updated_at при правке — специалист с открытой формой
--           получит от каскада 22023 «запись изменилась», хотя правил её
--           не человек;
--         - a00_readonly_guard (0050, before insert or update or delete) —
--           выходит по `auth.uid() is null`, а не потому, что действие не
--           запись. Держится на том, что сегодня физическое удаление идёт
--           без JWT (миграции/каскад/воркер). Если оно когда-нибудь поедет
--           из RPC под JWT владельца — SET NULL в read-only-центре получит
--           PT402 из таблицы, которую пользователь не трогал;
--         - apply_audit пишет строку с пустым актором — ожидаемая форма.
--
--   Р2. Индексы под составные FK — БЕЗ `where deleted_at is null`.
--       Партиальный индекс не может обслуживать проверку ссылочной
--       целостности: RI-запрос Postgres при DELETE родителя не содержит
--       предиката deleted_at, планировщик такой индекс не возьмёт —
--       проверено на реальных данных прод/staging: `lessons_teacher_fk`
--       (составной FK на teachers, частичный индекс `lessons_teacher_idx
--       (teacher_id, starts_at) where deleted_at is null`) всё равно в
--       списке unindexed_foreign_keys советника. Существующие партиальные
--       *_student_idx/*_center_idx/*_teacher_idx на всех таблицах ниже не
--       трогаются — они обслуживают запросы приложения (там deleted_at is
--       null есть в WHERE), это другая задача.
--       reading_writing_assessments_teacher_idx (0068 Р12, `(teacher_id)
--       where deleted_at is null`) — снимается: советник его не засчитывает
--       (тот же класс, что lessons_teacher_idx выше), а читателя у него нет
--       — apps/web фильтрует историю только по student_id (page.tsx). Держать
--       рядом с новым правильным индексом — платить записью за оба.
--
--   Р3. Объём: советник (`get_advisors`, performance) держит 109 находок
--       unindexed_foreign_keys по всей схеме на момент этой миграции — это
--       давний, распространённый пробел, не внесённый этой инициативой.
--       0069 закрывает ровно: FK, чей констрейнт переиздаёт раздел 1
--       (teacher_id/lesson_id на diagnostics/goal_progress/homework/
--       syllable_assessments), плюс обе составные FK (student_fk и
--       teacher_fk) на всех трёх таблицах речевой карты 0066-0068 — это
--       собственный долг сессии, отдельно зафиксированный в их шапках.
--       Остаток (goal_progress_goal_fk, homework_student_fk,
--       diagnostics_student_fk, diagnostics_conclusion_code_fkey,
--       lesson_participants_lesson_fk и весь остальной 101) — не в этом
--       объёме; критерий готовности для будущей чистки: непартиальный
--       btree-индекс, чьи ведущие колонки включают ВСЕ колонки FK (не имя
--       индекса — советник зачитывает частичные и по-разному считает
--       частичное совпадение префикса, полагаться на его «тишину» без
--       этого критерия нельзя; см. docs/Database.md).
--       Важно: этот раздел индексирует SET NULL-сторону пути удаления
--       родителя (Р1/Р2 — RI-проверка при DELETE teachers/lessons).
--       Каскадная сторона того же пути ОСТАЁТСЯ непокрытой —
--       lesson_participants_lesson_fk, homework_student_fk,
--       diagnostics_student_fk, goal_progress_goal_fk не индексируются
--       здесь. После 0069 `delete from centers`/будущий purge ADR-012
--       перестаёт падать на 23502, но не становится быстрым — на каждую
--       удаляемую строку lessons/students каскад всё ещё делает seq scan
--       по этим таблицам. Не в объёме этой миграции, зафиксировано, чтобы
--       не читалось как «путь удаления закрыт целиком».
-- =============================================================================


-- 1. Список колонок у составного `on delete set null` -----------------------

alter table public.diagnostics drop constraint diagnostics_teacher_fk;
alter table public.diagnostics add constraint diagnostics_teacher_fk
  foreign key (teacher_id, center_id) references public.teachers (id, center_id)
  on delete set null (teacher_id);

alter table public.goal_progress drop constraint goal_progress_lesson_fk;
alter table public.goal_progress add constraint goal_progress_lesson_fk
  foreign key (lesson_id, center_id) references public.lessons (id, center_id)
  on delete set null (lesson_id);

alter table public.homework drop constraint homework_lesson_fk;
alter table public.homework add constraint homework_lesson_fk
  foreign key (lesson_id, center_id) references public.lessons (id, center_id)
  on delete set null (lesson_id);

alter table public.syllable_assessments drop constraint syllable_assessments_teacher_fk;
alter table public.syllable_assessments add constraint syllable_assessments_teacher_fk
  foreign key (teacher_id, center_id) references public.teachers (id, center_id)
  on delete set null (teacher_id);


-- 2. Индексы покрытия составных FK, без where (Р2) --------------------------

create index if not exists diagnostics_teacher_fk_idx
  on public.diagnostics (teacher_id, center_id);
create index if not exists goal_progress_lesson_fk_idx
  on public.goal_progress (lesson_id, center_id);
create index if not exists homework_lesson_fk_idx
  on public.homework (lesson_id, center_id);

create index if not exists syllable_assessments_student_fk_idx
  on public.syllable_assessments (student_id, center_id);
create index if not exists syllable_assessments_teacher_fk_idx
  on public.syllable_assessments (teacher_id, center_id);

create index if not exists prosody_assessments_student_fk_idx
  on public.prosody_assessments (student_id, center_id);
create index if not exists prosody_assessments_teacher_fk_idx
  on public.prosody_assessments (teacher_id, center_id);

create index if not exists reading_writing_assessments_student_fk_idx
  on public.reading_writing_assessments (student_id, center_id);
create index if not exists reading_writing_assessments_teacher_fk_idx
  on public.reading_writing_assessments (teacher_id, center_id);

-- Плацебо 0068 Р12 — советник его не засчитывал, читателя в apps/web нет.
drop index if exists public.reading_writing_assessments_teacher_idx;
