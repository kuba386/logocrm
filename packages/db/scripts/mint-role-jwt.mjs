#!/usr/bin/env node
// Выпуск JWT для служебных ролей Supabase (bot_worker, public_booking) без
// зависимостей — HS256 на встроенном crypto. Секрет проекта никуда не
// уходит: скрипт запускается локально у владельца, секрет берётся из
// переменной окружения, в репозиторий и в чат не попадает.
//
// Использование:
//   SUPABASE_JWT_SECRET='<Project Settings → API → JWT Secret>' \
//     node packages/db/scripts/mint-role-jwt.mjs public_booking
//
// Роль — одна из bot_worker | public_booking (0032, 0057). Токен без sub,
// живёт 10 лет: ротация — выпуск нового и замена переменной окружения.

import { createHmac } from 'node:crypto'

const ROLES = new Set(['bot_worker', 'public_booking'])
const role = process.argv[2]
const secret = process.env.SUPABASE_JWT_SECRET

if (!role || !ROLES.has(role)) {
  console.error(`Укажите роль: ${[...ROLES].join(' | ')}`)
  process.exit(1)
}
if (!secret) {
  console.error('Нет SUPABASE_JWT_SECRET в окружении (Supabase → Project Settings → API → JWT Secret).')
  process.exit(1)
}

const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url')
const now = Math.floor(Date.now() / 1000)
const header = b64({ alg: 'HS256', typ: 'JWT' })
const payload = b64({ role, iss: 'supabase', iat: now, exp: now + 10 * 365 * 24 * 3600 })
const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url')

process.stdout.write(`${header}.${payload}.${signature}\n`)
