import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { toAppError } from '@/lib/errors'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { AddStudentDialog } from './add-student-dialog'
import { StudentsTable, type StudentRowView } from './students-table'

export const metadata = { title: 'Ученики — LogoCRM' }

export default async function StudentsPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')

  const isAdmin = role === 'owner' || role === 'admin'
  const isFinance = role === 'finance'
  const canSeeContacts = isAdmin || isFinance

  const { data: teachers } = await supabase
    .from('teachers')
    .select('id, full_name')
    .is('deleted_at', null)
    .eq('is_active', true)
    .order('full_name')

  const teacherOptions = (teachers ?? []).map((teacher) => ({
    id: teacher.id,
    fullName: teacher.full_name,
  }))
  const teacherNames = new Map(teacherOptions.map((teacher) => [teacher.id, teacher.fullName]))

  let students: StudentRowView[] = []

  if (isAdmin) {
    // Владелец и администратор читают таблицу с контактами плательщика.
    const { data } = await supabase
      .from('students')
      .select('id, full_name, birth_date, status, primary_teacher_id, payers(full_name, phone)')
      .is('deleted_at', null)
      .order('full_name')

    students = (data ?? []).map((row) => {
      const payer = row.payers as unknown as { full_name: string; phone: string } | null
      return {
        id: row.id,
        fullName: row.full_name,
        birthDate: row.birth_date,
        status: row.status,
        teacherId: row.primary_teacher_id,
        teacherName: row.primary_teacher_id ? (teacherNames.get(row.primary_teacher_id) ?? null) : null,
        payerName: payer?.full_name ?? null,
        payerPhone: payer?.phone ?? null,
      }
    })
  } else if (isFinance) {
    // Бухгалтер — students_brief/payers_brief: колонок с заметками там нет
    // физически, таблицы ему закрыты (0031).
    const [{ data: rows }, { data: payers }] = await Promise.all([
      supabase.rpc('students_brief').order('full_name'),
      supabase.rpc('payers_brief'),
    ])
    const payerById = new Map((payers ?? []).map((p) => [p.id, p]))

    students = (rows ?? []).map((row) => {
      const payer = row.payer_id ? payerById.get(row.payer_id) : undefined
      return {
        id: row.id,
        fullName: row.full_name,
        birthDate: row.birth_date,
        status: row.status,
        teacherId: row.primary_teacher_id,
        teacherName: row.primary_teacher_id ? (teacherNames.get(row.primary_teacher_id) ?? null) : null,
        payerName: payer?.full_name ?? null,
        payerPhone: payer?.phone ?? null,
      }
    })
  } else {
    // Специалист и родитель — только через витрину: колонки с телефоном там нет.
    const { data } = await supabase
      .from('students_teacher_view')
      .select('id, full_name, birth_date, status, primary_teacher_id, payer_full_name')
      .order('full_name')

    students = (data ?? [])
      .filter((row) => row.id !== null)
      .map((row) => ({
        id: row.id as string,
        fullName: row.full_name ?? '—',
        birthDate: row.birth_date,
        status: row.status ?? 'active',
        teacherId: row.primary_teacher_id,
        teacherName: row.primary_teacher_id ? (teacherNames.get(row.primary_teacher_id) ?? null) : null,
        payerName: row.payer_full_name,
        payerPhone: null,
      }))
  }

  // 0059 Р10: последнее заключение — только через RPC с ролью внутри.
  // diagnostics закрыта бухгалтеру и стойке, а специалисту — только свои:
  // embed отдал бы им пустой массив без ошибки, и фильтр в браузере считал
  // бы по неполным данным. Бухгалтеру не запрашиваем вовсе (0031 Р2).
  const conclusionByStudent = new Map<string, { code: string; name: string }>()
  let conclusionsError: string | null = null
  if (!isFinance) {
    const { data: conclusionRows, error } = await supabase.rpc('student_conclusions')
    if (error) {
      // Отказ RPC — не «ни у кого нет диагнозов»: показываем, а не прочерки.
      conclusionsError = toAppError(error, 'Не удалось загрузить заключения').message
    }
    for (const row of conclusionRows ?? []) {
      conclusionByStudent.set(row.student_id, { code: row.conclusion_code, name: row.conclusion_name })
    }
  }
  const studentsWithConclusions = students.map((s) => ({
    ...s,
    conclusionCode: conclusionByStudent.get(s.id)?.code ?? null,
    conclusionName: conclusionByStudent.get(s.id)?.name ?? null,
  }))

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Ученики</h1>
          <p className="text-sm text-muted-foreground">
            {isAdmin
              ? 'Контакты родителей — на карточке плательщика.'
              : isFinance
                ? 'Ученики центра: ФИО, статус, специалист, плательщик — без заметок.'
                : 'Вам видны дети, закреплённые за вами.'}
          </p>
        </div>
        {isAdmin ? <AddStudentDialog teachers={teacherOptions} /> : null}
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {students.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {conclusionsError ? (
            <p role="alert" className="mb-3 text-sm text-destructive">
              {conclusionsError}
            </p>
          ) : null}
          <StudentsTable
            students={studentsWithConclusions}
            teachers={teacherOptions}
            canSeeContacts={canSeeContacts}
          />
        </CardContent>
      </Card>
    </div>
  )
}
