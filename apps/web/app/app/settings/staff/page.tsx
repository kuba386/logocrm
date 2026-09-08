import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone } from '@/lib/timezone'
import { siteUrl } from '@/lib/env'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { InviteDialog, type TeacherOption } from './invite-dialog'
import { PendingInvitations, type PendingInvitation } from './pending-invitations'
import { StaffTable, type StaffMember } from './staff-table'

export const metadata = { title: 'Сотрудники — LogoCRM' }

export default async function StaffPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) {
    redirect('/login')
  }

  const { data: role } = await supabase.rpc('my_role')

  // Витрины и так закрыты RLS, но специалисту незачем видеть пустой экран
  // настроек — уводим его на дашборд.
  if (role !== 'owner' && role !== 'admin') {
    redirect('/app')
  }

  const [{ data: staff }, { data: pending }, { data: teachers }] = await Promise.all([
    supabase.from('staff_view').select('*').order('joined_at', { ascending: true }),
    supabase.from('pending_invitations_view').select('*').order('created_at', { ascending: false }),
    supabase
      .from('teachers')
      .select('id, full_name, profile_id')
      .is('deleted_at', null)
      .is('profile_id', null)
      .order('full_name'),
  ])

  const members: StaffMember[] = (staff ?? [])
    .filter((row) => row.user_id !== null)
    .map((row) => ({
      userId: row.user_id as string,
      email: row.email,
      role: row.role ?? 'teacher',
      fullName: row.full_name,
      isActive: row.is_active ?? true,
      joinedAt: row.joined_at,
      teacherId: row.teacher_id,
    }))

  const invitations: PendingInvitation[] = (pending ?? [])
    .filter((row) => row.id !== null && row.token !== null)
    .map((row) => ({
      id: row.id as string,
      role: row.role ?? 'teacher',
      fullName: row.full_name,
      phone: row.phone,
      email: row.email,
      url: `${siteUrl()}/invite/${row.token}`,
      expiresAt: row.expires_at as string,
    }))

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null
  const { data: center } = await supabase
    .from('centers')
    .select('settings')
    .eq('id', centerId ?? '')
    .maybeSingle()
  const timeZone = centerTimeZone(center?.settings)

  const teacherOptions: TeacherOption[] = (teachers ?? []).map((teacher) => ({
    id: teacher.id,
    fullName: teacher.full_name,
  }))

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Сотрудники</h1>
          <p className="text-sm text-muted-foreground">
            Доступ выдаётся по ссылке-приглашению. Ссылка действует 7 дней.
          </p>
        </div>
        <InviteDialog actorRole={role} teachers={teacherOptions} />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Участники центра</CardTitle>
          <CardDescription>Роль можно поменять прямо в таблице.</CardDescription>
        </CardHeader>
        <CardContent>
          <StaffTable
            members={members}
            actorRole={role}
            currentUserId={user.id}
            timeZone={timeZone}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Ожидают приглашения</CardTitle>
          <CardDescription>Ссылки, которыми ещё не воспользовались.</CardDescription>
        </CardHeader>
        <CardContent>
          <PendingInvitations invitations={invitations} />
        </CardContent>
      </Card>
    </div>
  )
}
