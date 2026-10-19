import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { StatusBadge } from '@/components/ui/status-badge'
import { DisableMakeupsForm, MakeupPolicyForm } from './makeup-forms'

export const metadata = { title: 'Отработки — LogoCRM' }

/**
 * Отработки пропусков (0105): срок и лимит. Право выдаёт база — по статусам
 * с флагом «Даёт право на отработку» (только списывающие: отработка за
 * оплаченный пропуск, решение владельца 19.10.2026).
 */
export default async function MakeupsSettingsPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const [{ data: policy }, { data: statuses }] = await Promise.all([
    supabase.from('makeup_policies').select('valid_days, per_subscription_limit').is('disabled_at', null).maybeSingle(),
    supabase.from('attendance_statuses').select('name').eq('grants_makeup', true).is('deleted_at', null).order('sort'),
  ])
  const enabled = Boolean(policy)
  const grantingNames = (statuses ?? []).map((s) => `«${s.name}»`).join(', ')

  return (
    <div className="space-y-6">
      <div>
        <h1 className="page-title">Отработки</h1>
        <p className="text-sm text-muted-foreground">
          Пропуск с отработкой списывает занятие, а взамен ученик может прийти на занятие той же услуги в другой группе или
          на индивидуальное — без списания. Записывают на отработку в карточке ученика.
        </p>
      </div>

      <Card>
        <CardHeader className="flex-row items-start justify-between gap-3 space-y-0">
          <div className="space-y-1.5">
            <CardTitle>Правила</CardTitle>
            <CardDescription>
              {enabled
                ? `Право дают статусы: ${grantingNames || 'ни один — отметьте флаг в «Статусах посещения»'}.`
                : 'После включения в отметке появится статус «Пропуск с отработкой»: занятие списывается, взамен — право на отработку.'}
            </CardDescription>
          </div>
          <StatusBadge tone={enabled ? 'success' : 'neutral'}>{enabled ? 'Включены' : 'Выключены'}</StatusBadge>
        </CardHeader>
        <CardContent className="space-y-4">
          <MakeupPolicyForm validDays={policy?.valid_days ?? null} limit={policy?.per_subscription_limit ?? null} />
          {enabled ? <DisableMakeupsForm /> : null}
        </CardContent>
      </Card>
    </div>
  )
}
