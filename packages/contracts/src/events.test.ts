import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { describe, expect, it } from 'vitest'

import { appEventSchema, appEventTypes, baseEventSchema, parseAppEvent } from './events'

describe('baseEventSchema', () => {
  it('требует формат «сущность.действие»', () => {
    expect(baseEventSchema.safeParse({ type: 'center.created', payload: {} }).success).toBe(true)
    expect(baseEventSchema.safeParse({ type: 'centerCreated', payload: {} }).success).toBe(false)
  })

  it('payload по умолчанию — пустой объект', () => {
    expect(baseEventSchema.parse({ type: 'center.created' }).payload).toEqual({})
  })
})

describe('appEventSchema', () => {
  it('разбирает center.created', () => {
    const event = appEventSchema.parse({
      type: 'center.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        name: 'Логопед Плюс',
        slug: 'logoped-plyus',
        city: 'Бишкек',
      },
    })
    expect(event.type).toBe('center.created')
  })

  it('разбирает membership.created', () => {
    const event = appEventSchema.parse({
      type: 'membership.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'owner',
      },
    })
    if (event.type !== 'membership.created') throw new Error('ожидался membership.created')
    expect(event.payload.role).toBe('owner')
  })

  it('отвергает неизвестную роль', () => {
    const result = appEventSchema.safeParse({
      type: 'membership.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'director',
      },
    })
    expect(result.success).toBe(false)
  })
})

describe('parseAppEvent', () => {
  it('возвращает ошибку вместо исключения для неизвестного типа', () => {
    const result = parseAppEvent({ type: 'lesson.rescheduled', payload: {} })
    expect(result.ok).toBe(false)
  })
})

describe('события этапа 1', () => {
  it('разбирает invitation.created', () => {
    const event = appEventSchema.parse({
      type: 'invitation.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        invitation_id: '00000000-0000-0000-0000-0000000000e1',
        role: 'teacher',
        teacher_id: '00000000-0000-0000-0000-0000000000t1'.replace(/t/g, 'a'),
      },
    })
    expect(event.type).toBe('invitation.created')
  })

  it('разбирает membership.revoked', () => {
    const event = appEventSchema.parse({
      type: 'membership.revoked',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        user_id: '00000000-0000-0000-0000-0000000000a1',
        role: 'teacher',
      },
    })
    if (event.type !== 'membership.revoked') throw new Error('ожидался membership.revoked')
    expect(event.payload.role).toBe('teacher')
  })

  it('teacher_id в invitation.created может быть null', () => {
    const event = appEventSchema.parse({
      type: 'invitation.created',
      payload: {
        center_id: '00000000-0000-0000-0000-0000000000c1',
        invitation_id: '00000000-0000-0000-0000-0000000000e1',
        role: 'parent',
        teacher_id: null,
      },
    })
    if (event.type !== 'invitation.created') throw new Error('ожидался invitation.created')
    expect(event.payload.teacher_id).toBeNull()
  })
})

describe('контракт не расходится с миграциями', () => {
  // Дрейф уже случался: registrar и finance появились в схеме на этапе 5, а в
  // перечислении ролей их не было, и события о назначении бухгалтера не
  // проходили разбор. parseAppEvent неизвестный тип пропускает молча (так и
  // задумано, ADR-003), поэтому расхождение не всплывает само — только здесь.
  const migrationsDir = fileURLToPath(new URL('../../db/supabase/migrations', import.meta.url))

  const emittedTypes = new Set<string>(
    readdirSync(migrationsDir)
      .filter((file) => file.endsWith('.sql'))
      .flatMap((file) =>
        readFileSync(join(migrationsDir, file), 'utf8')
          .split('\n')
          // Комментарии отрезаем: в шапках миграций типы событий упоминаются
          // прозой, и они не являются фактом эмиссии.
          .map((line) => line.split('--')[0] ?? '')
          .flatMap((line) => [
            // emit_clinical_event (0038) — тот же outbox, что emit_event, но
            // без проверки членства вызывающего (для триггеров статус-
            // перехода). Без него в регэкспе события, эмитируемые
            // триггерами goals/homework/lesson_notes, не попадали бы в
            // сравнение вовсе — тест был бы зелёным по недосмотру на
            // событии, у которого нет схемы (0045).
            ...line.matchAll(/emit_(?:clinical_event|event(?:_unchecked)?)\(\s*'([a-z_]+\.[a-z_]+)'/g),
          ])
          .map((match) => match[1] as string),
      ),
  )

  it('в миграциях вообще нашлись события — иначе тест зелёный по недосмотру', () => {
    expect(emittedTypes.size).toBeGreaterThan(30)
  })

  it('каждый тип, который шлёт SQL, имеет схему в контракте', () => {
    const known = new Set<string>(appEventTypes)
    const missing = [...emittedTypes].filter((type) => !known.has(type)).sort()
    expect(missing).toEqual([])
  })

  it('appEventTypes выведен из union и совпадает с ним по длине', () => {
    expect(new Set(appEventTypes).size).toBe(appEventTypes.length)
    expect(appEventTypes).toContain('digest.daily')
    expect(appEventTypes).toContain('membership.role_changed')
  })
})
