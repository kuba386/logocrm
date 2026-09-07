import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { STUDENT_STATUS_CLASSES, statusLabel, studentAge } from '@/lib/students'
import { StudentForm, type StudentFormValues } from './student-form'

export const metadata = { title: 'Карточка ученика — LogoCRM' }

export default async function StudentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')

  const isAdmin = role === 'owner' || role === 'admin'

  // Специалисту и родителю карточку отдаёт витрина — телефона в ней нет.
  const { data: base } = isAdmin
    ? await supabase
        .from('students')
        .select(
          'id, full_name, birth_date, gender, status, primary_teacher_id, source, notes, payer_id, created_at',
        )
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    : await supabase
        .from('students_teacher_view')
        .select('id, full_name, birth_date, gender, status, primary_teacher_id, notes, payer_full_name')
        .eq('id', id)
        .maybeSingle()

  if (!base) notFound()

  const { data: teachers } = await supabase
    .from('teachers')
    .select('id, full_name')
    .is('deleted_at', null)
    .order('full_name')

  const teacherOptions = (teachers ?? []).map((teacher) => ({
    id: teacher.id,
    fullName: teacher.full_name,
  }))
  const teacherName = base.primary_teacher_id
    ? (teacherOptions.find((teacher) => teacher.id === base.primary_teacher_id)?.fullName ?? null)
    : null

  const student: StudentFormValues = {
    id: base.id as string,
    fullName: base.full_name ?? '—',
    birthDate: base.birth_date,
    gender: base.gender,
    status: base.status ?? 'active',
    primaryTeacherId: base.primary_teacher_id,
    source: 'source' in base ? (base.source ?? null) : null,
    notes: base.notes,
  }

  const payer = isAdmin && 'payer_id' in base && base.payer_id
    ? (
        await supabase
          .from('payers')
          .select('id, full_name, phone, phone_alt, email, relation, notes')
          .eq('id', base.payer_id)
          .maybeSingle()
      ).data
    : null

  const payerName = payer?.full_name ?? ('payer_full_name' in base ? base.payer_full_name : null)

  // История изменений — только владельцу и администратору: в audit_log лежат
  // прежние значения строк целиком.
  const { data: history } = isAdmin
    ? await supabase
        .from('audit_log')
        .select('id, action, at, new_data')
        .eq('table_name', 'students')
        .eq('row_id', id)
        .order('at', { ascending: false })
        .limit(20)
    : { data: null }

  const waNumber = payer?.phone ? whatsappNumber(payer.phone) : null

  return (
    <div className="space-y-6">
      <div>
        <Link href="/app/students" className="text-sm text-muted-foreground hover:underline">
          ← Все ученики
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h1 className="text-2xl font-semibold tracking-tight">{student.fullName}</h1>
          <span
            className={cn(
              'rounded-full px-2 py-0.5 text-xs',
              STUDENT_STATUS_CLASSES[student.status] ?? 'bg-muted text-muted-foreground',
            )}
          >
            {statusLabel(student.status)}
          </span>
        </div>
        <p className="text-sm text-muted-foreground">
          {studentAge(student.birthDate)}
          {teacherName ? ` · специалист: ${teacherName}` : ' · специалист не назначен'}
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Данные</CardTitle>
          <CardDescription>
            {isAdmin ? 'Изменения сохраняются сразу.' : 'Редактирование доступно администратору центра.'}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <StudentForm student={student} teachers={teacherOptions} canEdit={isAdmin} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Плательщик</CardTitle>
          <CardDescription>
            {isAdmin ? 'Контакты для связи с семьёй.' : 'Контакты видны администратору центра.'}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="font-medium">{payerName ?? '—'}</p>

          {payer ? (
            <>
              <p className="text-sm text-muted-foreground">
                {payer.relation ?? 'родитель'} · {formatKgPhone(payer.phone)}
                {payer.email ? ` · ${payer.email}` : ''}
              </p>
              <div className="flex flex-wrap gap-2">
                <a href={`tel:${payer.phone}`} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                  Позвонить
                </a>
                {waNumber ? (
                  <a
                    href={`https://wa.me/${waNumber}`}
                    target="_blank"
                    rel="noreferrer"
                    className={buttonVariants({ variant: 'outline', size: 'sm' })}
                  >
                    WhatsApp
                  </a>
                ) : null}
                <Link
                  href={`/app/payers/${payer.id}`}
                  className={buttonVariants({ variant: 'ghost', size: 'sm' })}
                >
                  Карточка плательщика
                </Link>
              </div>
            </>
          ) : null}
        </CardContent>
      </Card>

      {isAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>История</CardTitle>
            <CardDescription>Последние изменения карточки.</CardDescription>
          </CardHeader>
          <CardContent>
            {history && history.length > 0 ? (
              <ul className="space-y-2 text-sm">
                {history.map((entry) => (
                  <li key={entry.id} className="flex gap-3">
                    <span className="text-muted-foreground">
                      {new Date(entry.at).toLocaleString('ru-RU')}
                    </span>
                    <span>
                      {entry.action === 'INSERT' ? 'Создана' : entry.action === 'UPDATE' ? 'Изменена' : 'Удалена'}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-muted-foreground">Изменений пока нет.</p>
            )}
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}
