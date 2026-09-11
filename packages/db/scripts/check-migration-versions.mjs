#!/usr/bin/env node
// Проверка, что номер миграции занят ровно один раз.
//
// Supabase различает миграции по числовому префиксу до первого подчёркивания
// — это и есть первичный ключ в supabase_migrations.schema_migrations. Два
// файла с одним префиксом дают `duplicate key value violates unique
// constraint "schema_migrations_pkey"`: db reset падает, за ним Playwright и
// деплой.
//
// Почему это не ловится само:
//   - git молчит. Имена файлов разные (0021_revenue_views.sql и
//     0021_center_scoped_fks.sql), конфликта при мерже нет, PR показывается
//     как mergeable;
//   - CI каждого PR по отдельности зелёный: на момент прогона номер ещё был
//     свободен. Ветки не видят номеров друг друга.
// 11.09.2026 два PR влились с разницей в минуту с номером 0021 и уронили
// main; до этого номер 0013 и 0014 уезжали дважды.
//
// Эта проверка закрывает случай «ветка отстала от main»: CI на pull_request
// гоняется поверх merge-коммита с main, и дубль виден сразу. Случай «два PR
// влились одновременно, оба зелёные» она НЕ ловит — от него защищает только
// настройка ветки «Require branches to be up to date before merging», и это
// тумблер в GitHub, а не код.

import { readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const dbRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

// Номер обязан быть уникальным внутри каталога. Обязателен же он только у
// миграций: там это первичный ключ schema_migrations. Тест имя которого не
// начинается с номера — законный случай (rls_smoke.test.sql), он просто не
// привязан к конкретной миграции и в сравнении номеров не участвует.
const dirs = [
  { path: join(dbRoot, 'supabase', 'migrations'), label: 'миграций', requireVersion: true },
  { path: join(dbRoot, 'supabase', 'tests'), label: 'тестов', requireVersion: false },
]

let failed = false

for (const { path, label, requireVersion } of dirs) {
  const files = readdirSync(path)
    .filter((name) => name.endsWith('.sql'))
    .sort()

  const byVersion = new Map()
  const malformed = []

  for (const name of files) {
    const version = name.split('_')[0]
    // Номер — ровно четыре цифры. У миграции без него Supabase не сможет
    // определить порядок применения; у теста номера может не быть вовсе.
    if (!/^\d{4}$/.test(version)) {
      if (requireVersion) malformed.push(name)
      continue
    }
    if (!byVersion.has(version)) byVersion.set(version, [])
    byVersion.get(version).push(name)
  }

  for (const name of malformed) {
    failed = true
    console.error(
      `✗ ${label}: у файла ${name} нет номера из четырёх цифр перед первым «_».`,
    )
  }

  for (const [version, names] of byVersion) {
    if (names.length < 2) continue
    failed = true
    const how = requireVersion
      ? '\n  Переименовать нужно тот файл, который ещё НЕ применён в staging,' +
        '\n  вместе с его тестом и всеми самоссылками в шапках (grep по номеру).' +
        '\n  Уже применённую миграцию не трогать: она неизменяема после мержа.'
      : '\n  Переименовать нужно тест той миграции, которая ещё не влита.'
    console.error(
      `✗ Номер ${version} занят ${names.length} раза в каталоге ${label}:\n` +
        names.map((n) => `    ${n}`).join('\n') +
        how,
    )
  }
}

if (failed) {
  console.error(
    '\nНомер берётся по факту каталога в момент начала этапа, а не из промта' +
      '\nв docs/Roadmap/stages.md — промты писались заранее и успели устареть.',
  )
  process.exit(1)
}

console.log('✓ Номера миграций и тестов уникальны.')
