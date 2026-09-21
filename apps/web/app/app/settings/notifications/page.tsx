import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { label, t } from '@/lib/messages'
import { TemplateForm } from './template-form'

export const metadata = { title: 'Уведомления — LogoCRM' }

/**
 * Порядок и состав — по типам событий, которые умеет рассылать база
 * (event_messages, 0034). Тип, которого здесь нет, сообщений не порождает, и
 * добавить его правкой текста нельзя — нужна миграция.
 */
const EVENTS: { type: string; placeholders: string[] }[] = [
  { type: 'lesson.reminder', placeholders: ['{child}', '{date}', '{time}', '{teacher}'] },
  { type: 'subscription.low_balance', placeholders: ['{child}', '{left}'] },
  { type: 'subscription.exhausted', placeholders: ['{child}'] },
  { type: 'student.absent_streak', placeholders: ['{child}', '{count}'] },
  { type: 'installment.due', placeholders: ['{child}', '{amount}', '{date}'] },
  { type: 'installment.overdue', placeholders: ['{child}', '{amount}', '{date}'] },
  { type: 'digest.daily', placeholders: ['{date}', '{lessons}', '{low}', '{debt}', '{overdue}'] },
  { type: 'report.monthly_ready', placeholders: ['{summary}', '{month}', '{child}'] },
  { type: 'homework.assigned', placeholders: ['{child}', '{due}'] },
  // whatsapp_link для homework.submitted не доставляется — у специалиста
  // нет своей WhatsApp-кнопки в интерфейсе. Дефолт этого канала намеренно
  // без {child} (0045 Р8) — не менять на содержательный текст.
  { type: 'homework.submitted', placeholders: ['{child}'] },
  { type: 'homework.reviewed', placeholders: ['{child}'] },
]

const CHANNELS = ['telegram', 'whatsapp_link'] as const

export default async function NotificationsSettingsPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  // Видны и строки центра, и дефолты платформы (center_id is null): политика
  // message_templates_read_defaults пускает к ним администрацию.
  const { data: rows } = await supabase
    .from('message_templates')
    .select('id, center_id, event_type, channel, text, is_active')
    .is('deleted_at', null)

  const byKey = new Map<string, { text: string; isActive: boolean; isOwn: boolean }>()
  for (const row of rows ?? []) {
    const key = `${row.event_type}:${row.channel}`
    const isOwn = row.center_id !== null
    // Строка центра перекрывает дефолт: если обе есть, побеждает своя.
    if (!byKey.has(key) || isOwn) {
      byKey.set(key, { text: row.text, isActive: row.is_active, isOwn })
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('notifications', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('notifications', 'subtitle')}</p>
      </div>

      {EVENTS.map((event) => (
        <Card key={event.type}>
          <CardHeader>
            <CardTitle className="text-base">{label('eventType', event.type)}</CardTitle>
            <CardDescription>{event.type}</CardDescription>
          </CardHeader>
          <CardContent className="grid gap-6 sm:grid-cols-2">
            {CHANNELS.map((channel) => {
              const current = byKey.get(`${event.type}:${channel}`)
              return (
                <TemplateForm
                  key={channel}
                  eventType={event.type}
                  channel={channel}
                  text={current?.text ?? ''}
                  isActive={current?.isActive ?? true}
                  isOwn={current?.isOwn ?? false}
                  placeholders={event.placeholders}
                />
              )
            })}
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
