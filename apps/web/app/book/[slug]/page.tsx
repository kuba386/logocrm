import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { createBookingClient } from '@/lib/supabase/booking'
import { t } from '@/lib/messages'
import { isoDayInZone } from '@/lib/timezone'
import { BookingForm } from './booking-form'

export const metadata = { title: 'Запись на занятие — LogoCRM' }

// Доступность записи (is_open, услуги, специалисты) — живые данные из RPC;
// Next.js кэширует fetch внутри Server Component по умолчанию, и без этого
// первый успешный рендер обслуживал бы всех следующих посетителей вечно
// (проявилось на проде: включили запись у центра, /book всё равно
// показывал «недоступна», пока не отключили кэш этой страницы).
export const dynamic = 'force-dynamic'

type BookingService = { id: string; name: string; duration_min: number }
type BookingTeacher = { id: string; full_name: string }

export default async function BookPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const supabase = createBookingClient()

  const { data, error } = await supabase.rpc('booking_center_info', { p_slug: slug })
  const info = data?.[0]

  if (error || !info?.is_open) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
        <Card className="w-full max-w-md">
          <CardHeader>
            <CardTitle>{t('booking', 'notFoundTitle')}</CardTitle>
            <CardDescription>{t('booking', 'notFoundDescription')}</CardDescription>
          </CardHeader>
        </Card>
      </main>
    )
  }

  const services = (info.services ?? []) as BookingService[]
  const teachers = (info.teachers ?? []) as BookingTeacher[]
  const timezone = info.timezone ?? 'Asia/Bishkek'
  const minDate = isoDayInZone(new Date(), timezone)

  return (
    <main className="flex min-h-screen items-center justify-center bg-muted/40 p-6">
      <Card className="w-full max-w-lg">
        <CardHeader>
          <CardTitle>{info.center_name}</CardTitle>
          <CardDescription>{t('booking', 'pageDescription')}</CardDescription>
        </CardHeader>
        <CardContent>
          {services.length === 0 || teachers.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('booking', 'noServices')}</p>
          ) : (
            <BookingForm slug={slug} services={services} teachers={teachers} minDate={minDate} timezone={timezone} />
          )}
        </CardContent>
      </Card>
    </main>
  )
}
