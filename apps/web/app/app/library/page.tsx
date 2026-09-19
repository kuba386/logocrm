import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { CatalogForm } from '@/components/ui/catalog-form'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { saveExercise } from './actions'
import { LibraryTable, type ExerciseRow, type StageOption, type StudentOption } from './library-table'

export const metadata = { title: 'Библиотека упражнений — LogoCRM' }

export default async function LibraryPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  // Библиотека — рабочий инструмент занятия: регистратору и бухгалтеру она
  // не нужна, а родителю нечего добавлять в ДЗ — он смотрит уже выданное
  // на карточке ребёнка.
  if (role !== 'owner' && role !== 'admin' && role !== 'teacher') redirect('/app')

  const isAdmin = role === 'owner' || role === 'admin'

  const [{ data: exerciseRows }, { data: stageRows }, { data: studentRows }] = await Promise.all([
    supabase
      .from('exercise_library')
      .select(
        'id, title, area, sound, stage_code, instructions, media_url, age_from, age_to, tags, is_active, center_id',
      )
      .is('deleted_at', null)
      .order('title'),
    supabase.from('goal_stages').select('code, title').is('deleted_at', null).order('sort'),
    isAdmin
      ? supabase.from('students').select('id, full_name').is('deleted_at', null).order('full_name')
      : supabase.from('students_teacher_view').select('id, full_name').order('full_name'),
  ])

  const stageTitleByCode = new Map((stageRows ?? []).map((s) => [s.code, s.title]))

  const exercises: ExerciseRow[] = (exerciseRows ?? []).map((row) => ({
    id: row.id,
    title: row.title,
    area: row.area,
    sound: row.sound,
    stageCode: row.stage_code,
    stageTitle: row.stage_code ? (stageTitleByCode.get(row.stage_code) ?? row.stage_code) : null,
    instructions: row.instructions,
    mediaUrl: row.media_url,
    ageFrom: row.age_from,
    ageTo: row.age_to,
    tags: row.tags ?? [],
    isActive: row.is_active,
    isPlatform: row.center_id === null,
  }))

  const stages: StageOption[] = (stageRows ?? []).map((s) => ({ code: s.code, title: s.title }))

  const students: StudentOption[] = (studentRows ?? [])
    .filter((s): s is { id: string; full_name: string } => Boolean(s.id))
    .map((s) => ({ id: s.id, fullName: s.full_name }))

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Библиотека упражнений</h1>
        <p className="text-sm text-muted-foreground">
          Общие упражнения платформы и свои упражнения центра — добавляйте в домашнее задание прямо
          отсюда.
        </p>
      </div>

      {isAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>Добавить упражнение</CardTitle>
            <CardDescription>Своё упражнение центра — платформенные правит только миграция.</CardDescription>
          </CardHeader>
          <CardContent>
            <CatalogForm action={saveExercise} label="Добавить">
              <div className="grid gap-3 sm:grid-cols-4">
                <div className="space-y-1 sm:col-span-2">
                  <Label htmlFor="title">Название</Label>
                  <Input id="title" name="title" placeholder="Дифференциация Р–Л в словах" required />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="area">Область</Label>
                  <Input id="area" name="area" placeholder="звукопроизношение" />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="sound">Звук</Label>
                  <Input id="sound" name="sound" placeholder="р" />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="stageCode">Этап</Label>
                  <Select id="stageCode" name="stageCode" defaultValue="">
                    <option value="">Без этапа</option>
                    {stages.map((stage) => (
                      <option key={stage.code} value={stage.code}>
                        {stage.title}
                      </option>
                    ))}
                  </Select>
                </div>
                <div className="space-y-1">
                  <Label htmlFor="ageFrom">Возраст от</Label>
                  <Input id="ageFrom" name="ageFrom" type="number" min="0" />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="ageTo">Возраст до</Label>
                  <Input id="ageTo" name="ageTo" type="number" min="0" />
                </div>
                <div className="space-y-1 sm:col-span-2">
                  <Label htmlFor="tags">Теги, через запятую</Label>
                  <Input id="tags" name="tags" placeholder="карточки, дом" />
                </div>
                <div className="space-y-1 sm:col-span-4">
                  <Label htmlFor="instructions">Инструкция</Label>
                  <Input id="instructions" name="instructions" placeholder="Как выполнять" />
                </div>
                <div className="space-y-1 sm:col-span-3">
                  <Label htmlFor="mediaUrl">Ссылка на материал</Label>
                  <Input id="mediaUrl" name="mediaUrl" type="url" placeholder="https://…" />
                </div>
                <label className="flex items-center gap-2 self-end text-sm">
                  <input type="checkbox" name="isActive" defaultChecked />
                  Активно
                </label>
              </div>
            </CatalogForm>
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>Упражнения</CardTitle>
          <CardDescription>Всего: {exercises.length}</CardDescription>
        </CardHeader>
        <CardContent>
          <LibraryTable exercises={exercises} stages={stages} students={students} isAdmin={isAdmin} />
        </CardContent>
      </Card>
    </div>
  )
}
