import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getCenterProfile } from '@/lib/center-profile'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { StatusBadge } from '@/components/ui/status-badge'
import { CenterKindForm, ModuleToggleForm } from './modules-forms'

export const metadata = { title: 'Тип и модули — LogoCRM' }

const MODULES = [
  {
    code: 'clinic',
    title: 'Клиника',
    description:
      'Обследование, речевая карта, цели по звукам, заключения для ПМПК, голосовые заметки с ИИ, месячный отчёт логопеда.',
  },
  {
    code: 'academic',
    title: 'Учёба',
    description: 'Уровни групп, оценки, табель и сертификаты. Разделы появятся в следующих обновлениях.',
  },
] as const

/**
 * Тип центра и модули (0104, ADR-013) — только владелец. Выключенный модуль
 * прячет разделы; данные не удаляются, специалисты и родители их не видят,
 * пока модуль выключен (решение владельца, Р6).
 */
export default async function ModulesPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner') redirect('/app')

  const profile = await getCenterProfile()

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Тип и модули</h1>
        <p className="text-sm text-muted-foreground">
          Тип центра меняет слова в интерфейсе. Модули добавляют разделы — выключенный модуль скрывается, но ничего не
          удаляет.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Тип центра</CardTitle>
          <CardDescription>Абонементы, расписание, деньги и данные учеников от типа не зависят.</CardDescription>
        </CardHeader>
        <CardContent>
          <CenterKindForm kind={profile.kind} />
        </CardContent>
      </Card>

      <section className="space-y-3" aria-labelledby="modules-title">
        <h2 id="modules-title" className="text-lg font-semibold">
          Модули
        </h2>
        {MODULES.map((module) => {
          const enabled = profile.modules.has(module.code)
          return (
            <Card key={module.code} role="group" aria-label={`Модуль «${module.title}»`}>
              <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
                <div className="space-y-1.5">
                  <CardTitle>{module.title}</CardTitle>
                  <CardDescription>{module.description}</CardDescription>
                </div>
                <StatusBadge tone={enabled ? 'success' : 'neutral'}>{enabled ? 'Включён' : 'Выключен'}</StatusBadge>
              </CardHeader>
              <CardContent className="space-y-2">
                {enabled && module.code === 'clinic' ? (
                  <p className="text-xs text-muted-foreground">
                    Если выключить: данные останутся, но специалисты и родители перестанут их видеть, а новые записи
                    обследований и целей станут недоступны.
                  </p>
                ) : null}
                <ModuleToggleForm code={module.code} enabled={enabled} />
              </CardContent>
            </Card>
          )
        })}
      </section>
    </div>
  )
}
