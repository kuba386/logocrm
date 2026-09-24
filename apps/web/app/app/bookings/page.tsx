import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { t } from '@/lib/messages'
import { isFrontDesk } from '@/lib/roles'
import { centerTimeZone, formatInTimeZone } from '@/lib/timezone'
import { BookingQueueRow } from './queue-row'

export const metadata = { title: 'Заявки с сайта — LogoCRM' }

type Row = {
  id: string
  child_name: string
  parent_name: string
  parent_phone: string
  starts_at: string
  teacher_id: string | null
  service_id: string | null
}

/**
 * Очередь заявок с публичной витрины (0057) — только status='new';
 * подтверждённые/отклонённые уходят из очереди, но не удаляются (RPC
 * confirm_booking_request/decline_booking_request хранят историю).
 */
export default async function BookingsPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!isFrontDesk(role)) redirect('/app')

  const { data: center } = await supabase.from('centers').select('settings').maybeSingle()
  const timezone = centerTimeZone(center?.settings)

  // teacher_id/service_id на booking_requests несут только составной FK
  // (center_id, X) — PostgREST embed через них нигде в кодовой базе не
  // используется (0022 Р6, PGRST201/тихая пустота), поэтому имена
  // подтягиваются отдельным запросом и Map, как в schedule/page.tsx.
  const [{ data: rows, error }, { data: teachers }, { data: services }] = await Promise.all([
    supabase
      .from('booking_requests')
      .select('id, child_name, parent_name, parent_phone, starts_at, teacher_id, service_id')
      .eq('status', 'new')
      .order('starts_at')
      .returns<Row[]>(),
    supabase.from('teachers').select('id, full_name'),
    supabase.from('services').select('id, name'),
  ])

  const teacherNames = new Map((teachers ?? []).map((tc) => [tc.id, tc.full_name]))
  const serviceNames = new Map((services ?? []).map((s) => [s.id, s.name]))

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle>{t('bookingQueue', 'title')}</CardTitle>
          <CardDescription>{t('bookingQueue', 'description')}</CardDescription>
        </CardHeader>
        <CardContent>
          {error ? (
            <p role="alert" className="text-sm text-destructive">
              {error.message}
            </p>
          ) : !rows || rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('bookingQueue', 'empty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('bookingQueue', 'colTime')}</TableHead>
                  <TableHead>{t('bookingQueue', 'colChild')}</TableHead>
                  <TableHead>{t('bookingQueue', 'colParent')}</TableHead>
                  <TableHead>{t('bookingQueue', 'colPhone')}</TableHead>
                  <TableHead>{t('bookingQueue', 'colTeacher')}</TableHead>
                  <TableHead>{t('bookingQueue', 'colService')}</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.id}>
                    <TableCell>{formatInTimeZone(r.starts_at, timezone, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</TableCell>
                    <TableCell>{r.child_name}</TableCell>
                    <TableCell>{r.parent_name}</TableCell>
                    <TableCell>{r.parent_phone}</TableCell>
                    <TableCell>{(r.teacher_id && teacherNames.get(r.teacher_id)) ?? '—'}</TableCell>
                    <TableCell>{(r.service_id && serviceNames.get(r.service_id)) ?? '—'}</TableCell>
                    <TableCell>
                      <BookingQueueRow requestId={r.id} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
