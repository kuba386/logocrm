import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone } from '@/lib/timezone'
import { AdminDashboard } from './dashboard-admin'
import { TeacherDashboard } from './dashboard-teacher'
import { ParentDashboard } from './dashboard-parent'

export const metadata = { title: 'Дашборд — LogoCRM' }

export default async function DashboardPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null
  const { data: center } = await supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle()
  const timeZone = centerTimeZone(center?.settings)

  // registrar/finance — дашборд администратора: выручку регистратору режут
  // политики 0028 (экран покажет пусто, не чужое), занятия бухгалтеру
  // закрыты 0031 — блок не рендерится, чтобы «0 занятий» не читалось как факт.
  if (role === 'owner' || role === 'admin' || role === 'registrar' || role === 'finance') {
    return <AdminDashboard timeZone={timeZone} finance={role !== 'registrar'} showLessons={role !== 'finance'} />
  }
  if (role === 'teacher') return <TeacherDashboard timeZone={timeZone} />
  if (role === 'parent') return <ParentDashboard timeZone={timeZone} />

  redirect('/select-center')
}
