import type { Metadata } from 'next'
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Landing } from '@/components/landing/landing'

export const metadata: Metadata = {
  title: 'LogoCRM — программа для логопедического центра',
  description:
    'Расписание без накладок, абонементы и долги, цели по звукам и отчёты родителям в Telegram. 14 дней бесплатно.',
}

export default async function HomePage() {
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (user) {
    redirect('/app')
  }

  return <Landing />
}
