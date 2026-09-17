import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { centerTimeZone, formatInTimeZone } from '@/lib/timezone'
import { label, t } from '@/lib/messages'
import { cn } from '@/lib/utils'

export const metadata = { title: 'Журнал отправок — LogoCRM' }

export default async function NotificationLogPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const since = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString()

  const [{ data: center }, { data: rows }] = await Promise.all([
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    supabase
      .from('notification_log')
      .select('id, event_id, channel, status, text, error, created_at')
      .gte('created_at', since)
      .order('created_at', { ascending: false })
      .limit(200),
  ])

  const timeZone = centerTimeZone(center?.settings)
  const log = rows ?? []

  // Тип события — из самой строки журнала его не видно, поэтому подтягиваем
  // events отдельным запросом по списку id.
  const eventIds = [...new Set(log.map((r) => r.event_id))]
  const { data: events } = eventIds.length
    ? await supabase.from('events').select('id, type').in('id', eventIds)
    : { data: [] as { id: number; type: string }[] }
  const typeById = new Map((events ?? []).map((e) => [e.id, e.type]))

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('notifications', 'logTitle')}</h1>
        <p className="text-sm text-muted-foreground">{t('notifications', 'logSubtitle')}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('notifications', 'logTitle')}</CardTitle>
          <CardDescription>Всего: {log.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {log.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('notifications', 'logEmpty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('notifications', 'colWhen')}</TableHead>
                  <TableHead>{t('notifications', 'colEvent')}</TableHead>
                  <TableHead>{t('notifications', 'colChannel')}</TableHead>
                  <TableHead>{t('notifications', 'colStatus')}</TableHead>
                  <TableHead>{t('notifications', 'colText')}</TableHead>
                  <TableHead>{t('notifications', 'colError')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {log.map((row) => {
                  const type = typeById.get(row.event_id)
                  return (
                    <TableRow key={row.id}>
                      <TableCell className="whitespace-nowrap">
                        {formatInTimeZone(row.created_at, timeZone, {
                          day: '2-digit',
                          month: '2-digit',
                          hour: '2-digit',
                          minute: '2-digit',
                        })}
                      </TableCell>
                      <TableCell>{type ? label('eventType', type) : '—'}</TableCell>
                      <TableCell className="text-muted-foreground">{label('notificationChannel', row.channel)}</TableCell>
                      <TableCell className={cn(row.status === 'failed' && 'text-destructive')}>
                        {label('notificationStatus', row.status)}
                      </TableCell>
                      <TableCell className="max-w-[24rem] truncate text-muted-foreground">{row.text ?? ''}</TableCell>
                      <TableCell className="max-w-[16rem] truncate text-destructive">{row.error ?? ''}</TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
