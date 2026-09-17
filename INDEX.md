# Индекс документов

Что где искать и кто/когда это читает — чтобы не открывать всё подряд.
Структура кода — [КАРТА_ПРОЕКТА.md](КАРТА_ПРОЕКТА.md).

## Обязательные к прочтению

| Документ | Когда читать |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Всегда загружен автоматически — правила процесса, применимые к любому этапу |
| [docs/Database.md](docs/Database.md) | Перед любой миграцией — конвенции таблиц, `apply_tenant_rls`, `apply_audit`, паттерны RLS |
| [docs/Roadmap/stages.md](docs/Roadmap/stages.md) | Источник истины по плану. Промт и чек-лист каждого этапа — здесь, не пересказывать по памяти. В шапке — «Перед этапом» (раздел Plan до кода), «Модель и effort», правила по контексту и Definition of Done |
| [docs/BUSINESS_RULES.md](docs/BUSINESS_RULES.md) | Что система не даёт сделать и чем это держится — констрейнт, политика или проверка в функции. Читать перед тем, как менять правило, и дополнять по Definition of Done |
| [docs/FEATURE_MATRIX.md](docs/FEATURE_MATRIX.md) | Кто что видит и может, по факту кода. Читать перед изменением прав; `registrar` и `finance` там пока план этапа 5 |

## Архитектура и решения

| Документ | Содержание |
|---|---|
| [docs/Architecture.md](docs/Architecture.md) | Мультитенантный SaaS, изоляция центров на уровне БД |
| [docs/Decisions/ADR-001](docs/Decisions/ADR-001-monorepo.md) | Почему монорепо на pnpm |
| [docs/Decisions/ADR-002](docs/Decisions/ADR-002-tenant-rls.md) | Изоляция тенантов через RLS + `center_id` в JWT |
| [docs/Decisions/ADR-003](docs/Decisions/ADR-003-events-outbox.md) | События — transactional outbox (таблица `events`) |
| [docs/Decisions/ADR-004](docs/Decisions/ADR-004-auth-environments.md) | Подтверждение email: выкл. на staging, обязательно на prod |
| [docs/Decisions/ADR-005](docs/Decisions/ADR-005-column-privacy.md) | Колоночная приватность (специалист видит ребёнка, не телефон матери) |
| [docs/Decisions/ADR-006](docs/Decisions/ADR-006-lesson-participants.md) | Состав занятия — отдельная таблица `lesson_participants` |
| [docs/Decisions/ADR-007](docs/Decisions/ADR-007-design-source.md) | Источник макетов — Stitch → структура/токены в shadcn, не копия HTML |
| [docs/Decisions/ADR-008](docs/Decisions/ADR-008-event-delivery.md) | Доставка событий: n8n забирает из очереди, Postgres не отправляет; роль `bot_worker` вместо `service_role` |

## Дизайн

| Документ | Содержание |
|---|---|
| [docs/Design/README.md](docs/Design/README.md) | Как макеты Stitch переносятся в код — коротко: см. ADR-007 |
| [docs/Design/DESIGN.md](docs/Design/DESIGN.md) | Токены Material 3 → переменные shadcn, 4+1 статусных цвета |
| [docs/Design/stage-4-brief.md](docs/Design/stage-4-brief.md) | Бриф экранов этапа 4 (посещения/абонементы) |
| [docs/Design/screens/*.png](docs/Design/screens/) | Сокращённые копии макетов, не пиксель-в-пиксель |

## Планирование и обратная связь

| Документ | Кто пишет / когда читать |
|---|---|
| [docs/Backlog.md](docs/Backlog.md) | Пожелания с живых показов логопедам. **Агент сам отсюда в работу ничего не берёт** — архитектор вплетает в этапы |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Keep a Changelog / SemVer |
| [reports/TEMPLATE.md](reports/TEMPLATE.md) | Шаблон отчёта по этапу — разделы «Что это даёт» и «Отступления от ТЗ» обязательны |
| [reports/stage-3.md](reports/stage-3.md), [reports/stage-4.md](reports/stage-4.md) | Отчёты по закрытым/частично закрытым этапам — писать/обновлять по ходу, не только в конце |

## Роли приложения (не документы — сквозной контекст)

Читается из БД при каждом заходе в `/app` (`apps/web/app/app/layout.tsx`), не из JWT — членство могли отозвать, пока токен жив.

| Роль | Видит |
|---|---|
| `owner` / `admin` | Всё в своём центре: деньги, справочники, все ученики. Разница между ними — управление персоналом (только owner) |
| `teacher` | Свои занятия и своих учеников; остаток абонемента — только словом (`есть`/`заканчивается`/`нет`), не числом; чужие центры/учеников не видит вовсе |
| `parent` | Своих детей на общей `/app` (ветвление по роли, не отдельный `/app/my` — CLAUDE.md, «одна страница на все роли»); остаток — числом (`student_balance` пускает по RLS) |

## Устаревшее — не использовать

- [AGENTS_1.md](AGENTS_1.md) — старая версия правил (Next.js 14, «один пользователь»); реальность и текущий источник истины — CLAUDE.md
- `logoped-crm/` (каталог в корне) — старый MVP, не переносится ни кодом, ни данными (решение 2026-09-09)
