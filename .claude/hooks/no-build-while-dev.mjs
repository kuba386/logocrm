#!/usr/bin/env node
// PreToolUse/Bash: не давать запустить production-сборку, пока жив дев-сервер.
// Оба пишут в один apps/web/.next: сборка затирает чанки дев-сервера и он
// начинает отдавать 500 (`Cannot find module './935.js'`).
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const allow = () => process.exit(0)

let payload
try {
  payload = JSON.parse(readFileSync(0, 'utf8'))
} catch {
  allow()
}

const command = payload?.tool_input?.command ?? ''
const isBuild = /(?:^|[;&|]\s*)(?:pnpm|npm|yarn|npx)\b[^;&|]*\bbuild\b/.test(command) || /\bnext\s+build\b/.test(command)
if (!isBuild) allow()

const ports = new Set([3000, 3100])
try {
  const launch = JSON.parse(readFileSync(new URL('../launch.json', import.meta.url), 'utf8'))
  for (const c of launch.configurations ?? []) if (c.port) ports.add(Number(c.port))
} catch {
  // launch.json может отсутствовать — остаются порты по умолчанию
}

const busy = []
for (const port of ports) {
  try {
    const pids = execFileSync('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    if (pids) busy.push(port)
  } catch {
    // lsof выходит с кодом 1, когда порт свободен
  }
}

if (busy.length === 0) allow()

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `Дев-сервер слушает порт ${busy.join(', ')}. ` +
        '`next build` пишет в тот же apps/web/.next и затрёт его чанки — все страницы отдадут 500. ' +
        'Для проверки кода используй `pnpm typecheck` и `pnpm lint`; если сборка правда нужна — сначала договорись с пользователем остановить дев-сервер.',
    },
  }),
)
