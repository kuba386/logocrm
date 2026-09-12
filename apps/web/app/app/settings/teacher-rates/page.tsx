import { redirect } from 'next/navigation'
import { formatSom } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { centerTimeZone, formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import { isFinance } from '@/lib/roles'
import { label, t } from '@/lib/messages'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { CatalogForm } from '@/components/ui/catalog-form'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { addTeacherRate } from './actions'

export const metadata = { title: 'Ставки специалистов — LogoCRM' }

const MODELS = ['per_lesson', 'per_hour', 'per_student', 'percent_payment'] as const

function rateValue(model: string, value: number): string {
  return model === 'percent_payment' ? `${(value / 100).toFixed(2).replace(/\.?0+$/, '')} %` : formatSom(value)
}

function calendarDate(day: string, timeZone: string): string {
  return formatInTimeZone(`${day}T12:00:00Z`, timeZone, { day: '2-digit', month: '2-digit', year: 'numeric' })
}

export default async function TeacherRatesPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Ставки — деньги сотрудников: owner/admin/finance (tenant_finance_insert, 0028).
  const { data: role } = await supabase.rpc('my_role')
  if (!isFinance(role)) redirect('/app')

  const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? ''
  const [{ data: center }, { data: rates }, { data: teachers }, { data: services }] = await Promise.all([
    supabase.from('centers').select('settings').eq('id', centerId).maybeSingle(),
    supabase
      .from('teacher_rates')
      .select('id, teacher_id, service_id, model, value, valid_from')
      .order('valid_from', { ascending: false })
      .limit(200),
    supabase.from('teachers').select('id, full_name').is('deleted_at', null).order('full_name'),
    supabase.from('services').select('id, name').is('deleted_at', null).order('name'),
  ])
  const timeZone = centerTimeZone(center?.settings)
  const today = isoDayInZone(new Date(), timeZone)
  const teacherName = new Map((teachers ?? []).map((tr) => [tr.id, tr.full_name]))
  const serviceName = new Map((services ?? []).map((s) => [s.id, s.name]))
  const rows = rates ?? []

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('teacherRates', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('teacherRates', 'subtitle')}</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>{t('teacherRates', 'add')}</CardTitle>
          <CardDescription>
            {t('teacherRates', 'valueSom')} — для «за занятие», «за час», «за ученика»; {t('teacherRates', 'valuePercent')} — для
            «процент от оплаты».
          </CardDescription>
        </CardHeader>
        <CardContent>
          <CatalogForm action={addTeacherRate} label={t('teacherRates', 'submit')}>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="rate-teacher">{t('teacherRates', 'teacher')}</Label>
                <Select id="rate-teacher" name="teacherId" required defaultValue="">
                  <option value="">{t('teacherRates', 'chooseTeacher')}</option>
                  {(teachers ?? []).map((tr) => (
                    <option key={tr.id} value={tr.id}>
                      {tr.full_name}
                    </option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="rate-service">{t('teacherRates', 'service')}</Label>
                <Select id="rate-service" name="serviceId" defaultValue="">
                  <option value="">{t('teacherRates', 'allServices')}</option>
                  {(services ?? []).map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="rate-model">{t('teacherRates', 'model')}</Label>
                <Select id="rate-model" name="model" defaultValue="per_lesson">
                  {MODELS.map((m) => (
                    <option key={m} value={m}>
                      {label('salary', `model_${m}`)}
                    </option>
                  ))}
                </Select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="rate-value">{t('teacherRates', 'value')}</Label>
                <Input id="rate-value" name="value" type="number" min={0} step="0.01" required />
              </div>
              <div className="space-y-1">
                <Label htmlFor="rate-valid-from">{t('teacherRates', 'validFrom')}</Label>
                <Input id="rate-valid-from" name="validFrom" type="date" defaultValue={today} required />
              </div>
            </div>
          </CatalogForm>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t('teacherRates', 'title')}</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t('teacherRates', 'empty')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('teacherRates', 'colTeacher')}</TableHead>
                  <TableHead>{t('teacherRates', 'colService')}</TableHead>
                  <TableHead>{t('teacherRates', 'colModel')}</TableHead>
                  <TableHead className="text-right">{t('teacherRates', 'colValue')}</TableHead>
                  <TableHead>{t('teacherRates', 'colValidFrom')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((r) => (
                  <TableRow key={r.id}>
                    <TableCell className="font-medium">{teacherName.get(r.teacher_id) ?? '—'}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {r.service_id ? (serviceName.get(r.service_id) ?? '—') : t('teacherRates', 'allServices')}
                    </TableCell>
                    <TableCell>{label('salary', `model_${r.model}`)}</TableCell>
                    <TableCell className="text-right">{rateValue(r.model, r.value)}</TableCell>
                    <TableCell className="whitespace-nowrap">{calendarDate(r.valid_from, timeZone)}</TableCell>
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
