#!/usr/bin/env node
// PreToolUse/Edit|Write: предупредить о правке миграции, которая уже влита в main.
// Схема катится в staging из main (deploy-staging.yml по workflow_run на успех CI),
// поэтому «файл есть в origin/main» == «миграция уже применена». Локальных
// credentials к базе у хука нет, и это единственный честный источник правды.
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { relative, resolve } from 'node:path'

const allow = () => process.exit(0)

let payload
try {
  payload = JSON.parse(readFileSync(0, 'utf8'))
} catch {
  allow()
}

const filePath = payload?.tool_input?.file_path ?? ''
if (!/packages\/db\/supabase\/migrations\/.+\.sql$/.test(filePath)) allow()

const git = (args) =>
  execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()

let repoRoot
let tracked
try {
  repoRoot = git(['rev-parse', '--show-toplevel'])
  tracked = relative(repoRoot, resolve(filePath))
} catch {
  allow()
}

let merged = false
try {
  git(['cat-file', '-e', `origin/main:${tracked}`])
  merged = true
} catch {
  // нет в origin/main — новая миграция, править можно свободно
}
if (!merged) allow()

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'ask',
      permissionDecisionReason:
        `${tracked} уже влит в origin/main, то есть применён в staging. ` +
        'Правка изменит файл, но не базу: локальная история и схема разойдутся, и расхождение всплывёт нескоро. ' +
        'Изменения схемы вносятся новой миграцией. Править существующую можно, только если она ещё не доехала до базы.',
    },
  }),
)
