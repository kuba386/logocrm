import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { centerTimeZone, dayInZone } from '@/lib/timezone'
import { t } from '@/lib/messages'
import { TelegramPanel } from './telegram-panel'

export const metadata = { title: 'Telegram — LogoCRM' }

/**
 * Личная привязка чата — страница для всех ролей, а не раздел настроек
 * центра: Telegram нужен прежде всего родителю, а настройки в меню видит
 * только администрация. Отступление от плана этапа, где это был
 * /app/settings/integrations.
 */
export default async function TelegramPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [{ data: center }, { data: account }] = await Promise.all([
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    supabase
      .from('telegram_accounts')
      .select('linked_at')
      .is('unlinked_at', null)
      .maybeSingle(),
  ])

  const timeZone = centerTimeZone(center?.settings)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('integrations', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('integrations', 'subtitle')}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('integrations', 'telegramTitle')}</CardTitle>
          <CardDescription>
            {account
              ? t('integrations', 'linked', { at: dayInZone(account.linked_at, timeZone) })
              : t('integrations', 'notLinked')}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <TelegramPanel linked={Boolean(account)} botName={process.env.NEXT_PUBLIC_TELEGRAM_BOT ?? null} />
        </CardContent>
      </Card>
    </div>
  )
}
