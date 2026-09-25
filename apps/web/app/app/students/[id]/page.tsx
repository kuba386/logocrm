import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { centerTimeZone, formatInTimeZone, isoDayInZone } from '@/lib/timezone'
import { STUDENT_STATUS_CLASSES, statusLabel, studentAge, type FunnelStage } from '@/lib/students'
import { FunnelStageWidget } from './funnel-stage-widget'
import type { GoalTrend } from '@/lib/goal-trend'
import { StudentForm, type StudentFormValues } from './student-form'
import {
  SubscriptionsPanel,
  type AttendanceHistoryRow,
  type BalanceView,
  type SiblingOption,
  type SourceOption,
  type SubscriptionTypeOption,
  type SubscriptionView,
} from './subscriptions-panel'
import { DiagnosticsPanel, type DiagnosticEntry } from './diagnostics-panel'
import { AnamnesisPanel, type AnamnesisEntry } from './anamnesis-panel'
import { ArticulationPanel, type ArticulationEntry } from './articulation-panel'
import { SyllableAssessmentPanel, type SyllableAssessmentEntry } from './syllable-assessment-panel'
import { GoalsPanel, type GoalEntry, type GoalStageOption } from './goals-panel'
import { HomeworkPanel, type ExerciseOption, type HomeworkEntry } from './homework-panel'
import { MonthlyReportPanel, type MonthOption } from './monthly-report-panel'
import type { MonthlyReport } from './clinical-actions'
import { NotesPanel, type NoteEntry, type NoteSoap } from './notes-panel'

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
  const isRegistrar = role === 'registrar'
  const isFinance = role === 'finance'
  const isTeacher = role === 'teacher'
  const isParent = role === 'parent'
  // Клиника положена тем же ролям, что в 0036 (registrar/finance — ни строки).
  const clinicalAllowed = isAdmin || isTeacher || isParent
  const canWriteClinical = isAdmin || isTeacher

  // Специалисту и родителю карточку отдаёт витрина — телефона в ней нет;
  // бухгалтеру — students_brief: ни телефона, ни заметок (0031). Стойка
  // (registrar) читает students напрямую тем же select — apply_role_rls уже
  // даёт ей 'write' на students (0028), сужения здесь не добавляют: без
  // своей ветки registrar получал бы витрину без funnel_stage и не видел
  // бы виджет воронки, хотя set_funnel_stage/funnel_stuck ей открыты (0055
  // Р12, ревью написанного SQL 23.09.2026, находка 5).
  const { data: base } = isAdmin || isRegistrar
    ? await supabase
        .from('students')
        .select(
          'id, full_name, birth_date, gender, status, funnel_stage, primary_teacher_id, source, notes, payer_id, created_at',
        )
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    : isFinance
      ? await supabase.rpc('students_brief').eq('id', id).maybeSingle()
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
    gender: 'gender' in base ? base.gender : null,
    status: base.status ?? 'active',
    primaryTeacherId: base.primary_teacher_id,
    source: 'source' in base ? (base.source ?? null) : null,
    notes: 'notes' in base ? base.notes : null,
  }

  const payer = isAdmin && 'payer_id' in base && base.payer_id
    ? (
        await supabase
          .from('payers')
          .select('id, full_name, phone, phone_alt, email, relation, notes')
          .eq('id', base.payer_id)
          .maybeSingle()
      ).data
    : isFinance && 'payer_id' in base && base.payer_id
      ? (await supabase.rpc('payers_brief').eq('id', base.payer_id).maybeSingle()).data
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

  // Специалисту — только слово (student_subscription_badge): деньги центра
  // не его дело (ADR-005). Родителю раньше доставался тот же бейдж — теперь
  // те же цифры, что admin/owner, но без единой кнопки (см. subscriptionsSection
  // ниже, ветка isParent; Backlog.md, 23.09.2026).
  const subscriptionBadge = isTeacher
    ? (await supabase.rpc('student_subscription_badge', { p_student_id: id })).data
    : null

  let subscriptionsSection: {
    balance: BalanceView
    subscriptions: SubscriptionView[]
    types: SubscriptionTypeOption[]
    sources: SourceOption[]
    today: string
    siblings: SiblingOption[]
    attendanceHistory: AttendanceHistoryRow[]
    timeZone: string
    /** owner/admin — продажа/заморозка/возврат/перенос; родитель — только чтение. */
    canManage: boolean
  } | null = null

  if (isAdmin) {
    const payerId = 'payer_id' in base ? base.payer_id : null
    const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null

    const [
      { data: subsRows },
      { data: typeRows },
      { data: balanceRow },
      { data: siblingRows },
      { data: attendanceRows },
      { data: center },
      { data: sourceRows },
    ] = await Promise.all([
        supabase
          .from('subscriptions')
          .select('id, type_id, price_tiyin, starts_at, ends_at')
          .eq('student_id', id)
          .is('deleted_at', null)
          .order('created_at', { ascending: false }),
        // Без фильтров: имя нужно и для архивных/неактивных типов — они
        // остаются на уже проданных абонементах (находка C, архив 0012).
        // В форму продажи ниже попадают только is_active и не архивные.
        supabase
          .from('subscription_types')
          .select('id, name, kind, price_tiyin, lessons_count, period_days, is_active, deleted_at')
          .order('name'),
        supabase
          .from('student_balance')
          .select('active_subscription_id, lessons_left, ends_at, debt_tiyin, overdrawn_tiyin')
          .eq('student_id', id)
          .maybeSingle(),
        payerId
          ? supabase.from('students').select('id, full_name').eq('payer_id', payerId).neq('id', id).is('deleted_at', null)
          : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
        supabase
          .from('attendance')
          .select('id, lesson_id, status_id, comment')
          .eq('student_id', id)
          .order('created_at', { ascending: false })
          .limit(20),
        supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle(),
        // Источники оплаты для формы продажи: только живые; архивный источник
        // record_payment примет (известное ограничение 0016), но предлагать его
        // в форме незачем.
        supabase
          .from('payment_sources')
          .select('id, name')
          .eq('is_active', true)
          .is('deleted_at', null)
          .order('sort'),
      ])

    const typeNameById = new Map((typeRows ?? []).map((t) => [t.id, t.name]))
    const subscriptionIds = (subsRows ?? []).map((row) => row.id)

    // Оплата и рассрочка — с сервера (subscription_payment_summary,
    // installments_view), не из суммы платежей в браузере.
    const [paymentSummaries, { data: installmentRows }] = await Promise.all([
      Promise.all(
        subscriptionIds.map((subscriptionId) =>
          supabase.rpc('subscription_payment_summary', { p_subscription_id: subscriptionId }),
        ),
      ),
      subscriptionIds.length
        ? supabase
            .from('installments_view')
            .select('subscription_id, seq, due_date, amount_tiyin, state, cancelled_at')
            .in('subscription_id', subscriptionIds)
            .is('cancelled_at', null)
            .order('seq')
        : Promise.resolve({ data: [] as { subscription_id: string | null; seq: number | null; due_date: string | null; amount_tiyin: number | null; state: string | null; cancelled_at: string | null }[] }),
    ])

    // Границы текущей заморозки — из subscription_summary (freeze_from/
    // freeze_to, последний замороженный день уже посчитан на сервере как
    // upper(period) - 1), а не разбором daterange-текста на клиенте: тот
    // разбор был вторым источником правды о заморозке рядом с subscription_
    // state и мог показать не ту же дату, что называет исключение при
    // отметке (0015_freeze_state_unification.sql, раздел 8).
    const summaries = await Promise.all(
      (subsRows ?? []).map((row) => supabase.rpc('subscription_summary', { p_subscription_id: row.id })),
    )

    const subscriptions: SubscriptionView[] = (subsRows ?? []).map((row, index) => {
      const summary = summaries[index]?.data?.[0]
      return {
        id: row.id,
        typeName: row.type_id ? (typeNameById.get(row.type_id) ?? 'Абонемент') : 'Абонемент',
        priceTiyin: row.price_tiyin,
        startsAt: row.starts_at,
        endsAt: row.ends_at,
        lessonsLeft: summary?.lessons_left ?? null,
        // '' — не значение state, честный "неизвестно" на случай отказа
        // RPC: подстановка 'active' сюда показала бы "Действует" для,
        // например, отменённого абонемента. SUBSCRIPTION_STATE_LABELS/
        // _CLASSES в subscriptions-panel.tsx уже падают на нейтральный
        // вид при неизвестном ключе (?? в обоих лукапах).
        state: summary?.state ?? '',
        freezeDays: summary?.freeze_days ?? 0,
        refundTiyin: summary?.refund_tiyin ?? 0,
        freezeFrom: summary?.freeze_from ?? null,
        freezeTo: summary?.freeze_to ?? null,
        paidTiyin: paymentSummaries[index]?.data?.[0]?.paid_tiyin ?? 0,
        paymentState: paymentSummaries[index]?.data?.[0]?.payment_state ?? '',
        installments: (installmentRows ?? [])
          .filter((r) => r.subscription_id === row.id && r.seq != null && r.due_date && r.amount_tiyin != null)
          .map((r) => ({
            seq: r.seq as number,
            dueDate: r.due_date as string,
            amountTiyin: r.amount_tiyin as number,
            state: r.state ?? '',
          })),
      }
    })

    const attendanceRowsData = attendanceRows ?? []
    const lessonIds = attendanceRowsData.map((a) => a.lesson_id)
    const statusIds = attendanceRowsData.map((a) => a.status_id).filter((v): v is string => Boolean(v))

    const [{ data: lessonRows }, { data: statusRows }] = await Promise.all([
      lessonIds.length
        ? supabase.from('lessons').select('id, starts_at').in('id', lessonIds)
        : Promise.resolve({ data: [] as { id: string; starts_at: string }[] }),
      statusIds.length
        ? supabase.from('attendance_statuses').select('id, name, color').in('id', statusIds)
        : Promise.resolve({ data: [] as { id: string; name: string; color: string }[] }),
    ])

    const lessonStartById = new Map((lessonRows ?? []).map((l) => [l.id, l.starts_at]))
    const statusById = new Map((statusRows ?? []).map((s) => [s.id, s]))

    subscriptionsSection = {
      balance: {
        lessonsLeft: balanceRow?.lessons_left ?? null,
        activeSubscriptionId: balanceRow?.active_subscription_id ?? null,
        endsAt: balanceRow?.ends_at ?? null,
        debtTiyin: balanceRow?.debt_tiyin ?? 0,
        overdrawnTiyin: balanceRow?.overdrawn_tiyin ?? 0,
      },
      subscriptions,
      types: (typeRows ?? [])
        .filter((t) => t.is_active && !t.deleted_at)
        .map((t) => ({
          id: t.id,
          name: t.name,
          kind: t.kind,
          priceTiyin: t.price_tiyin,
          lessonsCount: t.lessons_count,
          periodDays: t.period_days,
        })),
      siblings: (siblingRows ?? []).map((s) => ({ id: s.id, fullName: s.full_name })),
      sources: (sourceRows ?? []).map((s) => ({ id: s.id, name: s.name })),
      today: isoDayInZone(new Date(), centerTimeZone(center?.settings)),
      timeZone: centerTimeZone(center?.settings),
      attendanceHistory: attendanceRowsData.map((row) => {
        const status = row.status_id ? statusById.get(row.status_id) : undefined
        return {
          id: row.id,
          startsAt: lessonStartById.get(row.lesson_id) ?? '',
          statusName: status?.name ?? '—',
          statusColor: status?.color ?? 'green',
          comment: row.comment,
        }
      }),
      canManage: true,
    }
  } else if (isParent) {
    // Родителю — то же самое «Оплачено X из Y», статус и график рассрочки,
    // что видит владелец, но без действий и без вкладки «Посещения»
    // (attendance родителю закрыта целиком, 0044_attendance_comment_privacy.sql).
    // Источник — RLS subscriptions_parent_read/installments_parent_read/
    // student_balance, RPC subscription_summary/subscription_payment_summary
    // (обе проверяют subscription_visible_to_caller, родителя пускают) — те
    // же вызовы, что уже использует dashboard-parent.tsx, просто на одного
    // ребёнка вместо всех сразу. Имя типа абонемента родителю не отдаётся
    // (subscription_types закрыт ему RLS) — общий фолбэк «Абонемент», как и
    // у admin-ветки для абонемента без типа.
    const centerId = (user.app_metadata as { center_id?: string })?.center_id ?? null

    const [{ data: subsRows }, { data: balanceRow }, { data: center }] = await Promise.all([
      supabase
        .from('subscriptions')
        .select('id, type_id, price_tiyin, starts_at, ends_at')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false }),
      supabase
        .from('student_balance')
        .select('active_subscription_id, lessons_left, ends_at, debt_tiyin, overdrawn_tiyin')
        .eq('student_id', id)
        .maybeSingle(),
      supabase.from('centers').select('settings').eq('id', centerId ?? '').maybeSingle(),
    ])

    const subscriptionIds = (subsRows ?? []).map((row) => row.id)

    const [paymentSummaries, { data: installmentRows }, summaries] = await Promise.all([
      Promise.all(
        subscriptionIds.map((subscriptionId) =>
          supabase.rpc('subscription_payment_summary', { p_subscription_id: subscriptionId }),
        ),
      ),
      subscriptionIds.length
        ? supabase
            .from('installments_view')
            .select('subscription_id, seq, due_date, amount_tiyin, state, cancelled_at')
            .in('subscription_id', subscriptionIds)
            .is('cancelled_at', null)
            .order('seq')
        : Promise.resolve({ data: [] as { subscription_id: string | null; seq: number | null; due_date: string | null; amount_tiyin: number | null; state: string | null; cancelled_at: string | null }[] }),
      Promise.all((subsRows ?? []).map((row) => supabase.rpc('subscription_summary', { p_subscription_id: row.id }))),
    ])

    const subscriptions: SubscriptionView[] = (subsRows ?? []).map((row, index) => {
      const summary = summaries[index]?.data?.[0]
      return {
        id: row.id,
        typeName: 'Абонемент',
        priceTiyin: row.price_tiyin,
        startsAt: row.starts_at,
        endsAt: row.ends_at,
        lessonsLeft: summary?.lessons_left ?? null,
        state: summary?.state ?? '',
        freezeDays: summary?.freeze_days ?? 0,
        refundTiyin: summary?.refund_tiyin ?? 0,
        freezeFrom: summary?.freeze_from ?? null,
        freezeTo: summary?.freeze_to ?? null,
        paidTiyin: paymentSummaries[index]?.data?.[0]?.paid_tiyin ?? 0,
        paymentState: paymentSummaries[index]?.data?.[0]?.payment_state ?? '',
        installments: (installmentRows ?? [])
          .filter((r) => r.subscription_id === row.id && r.seq != null && r.due_date && r.amount_tiyin != null)
          .map((r) => ({
            seq: r.seq as number,
            dueDate: r.due_date as string,
            amountTiyin: r.amount_tiyin as number,
            state: r.state ?? '',
          })),
      }
    })

    subscriptionsSection = {
      balance: {
        lessonsLeft: balanceRow?.lessons_left ?? null,
        activeSubscriptionId: balanceRow?.active_subscription_id ?? null,
        endsAt: balanceRow?.ends_at ?? null,
        debtTiyin: balanceRow?.debt_tiyin ?? 0,
        overdrawnTiyin: balanceRow?.overdrawn_tiyin ?? 0,
      },
      subscriptions,
      types: [],
      sources: [],
      siblings: [],
      today: isoDayInZone(new Date(), centerTimeZone(center?.settings)),
      timeZone: centerTimeZone(center?.settings),
      attendanceHistory: [],
      canManage: false,
    }
  }

  // Клиника (0036/0038): те же роли, что уже проверяет RLS. Родителю —
  // узкие definer-функции (Р4 в 0036: карта звуков и заметка специалиста
  // родителю не положены физически), admin/teacher — полные таблицы, RLS
  // сама сузит видимость у teacher по clinical_teacher_sees.
  let clinicalSection: {
    diagnostics: DiagnosticEntry[]
    goals: GoalEntry[]
    stages: GoalStageOption[]
    homework: HomeworkEntry[]
    exercises: ExerciseOption[]
    notes: NoteEntry[]
  } | null = null

  // Анамнез (0063) — рабочий материал специалиста, тот же класс, что
  // sounds/speech_areas (ADR-005): родителю не видна ни в каком виде,
  // поэтому отдельно от clinicalSection (тот делится с parent-веткой).
  let anamnesis: AnamnesisEntry | null = null
  const showAnamnesis = isAdmin || isTeacher

  // Артикуляционный аппарат (0065) — тот же класс данных и та же
  // видимость, что анамнез.
  let articulation: ArticulationEntry | null = null
  const showArticulation = isAdmin || isTeacher

  // Слоговая структура (0066) — ИСТОРИЯ, не профиль (в отличие от анамнеза
  // и артикуляции): несколько записей на ребёнка, та же видимость.
  let syllableAssessments: SyllableAssessmentEntry[] = []
  const showSyllableAssessments = isAdmin || isTeacher

  // Дата заметки рендерится в поясе центра — та же дата, что уходит
  // родителю в Telegram (0047); пояс браузера здесь не годится.
  const clinicalCenterId = (user.app_metadata as { center_id?: string })?.center_id ?? null
  const { data: clinicalCenter } = clinicalAllowed
    ? await supabase.from('centers').select('settings').eq('id', clinicalCenterId ?? '').maybeSingle()
    : { data: null }
  const clinicalTimeZone = centerTimeZone(clinicalCenter?.settings)

  // Отчёт за месяц (0043): текущий месяц в поясе центра плюс пять
  // предыдущих; первый отчёт грузится здесь, смена месяца — действием.
  const reportMonths: MonthOption[] = []
  if (clinicalAllowed) {
    const today = isoDayInZone(new Date(), clinicalTimeZone)
    const [y, m] = today.split('-').map(Number)
    for (let i = 0; i < 6; i += 1) {
      const d = new Date(Date.UTC(y!, m! - 1 - i, 1))
      const value = d.toISOString().slice(0, 10)
      const label = formatInTimeZone(d, 'UTC', { month: 'long', year: 'numeric' })
      reportMonths.push({ value, label: label.charAt(0).toUpperCase() + label.slice(1) })
    }
  }
  const initialReportMonth = reportMonths[0]?.value ?? null
  const { data: initialReport } = initialReportMonth
    ? await supabase.rpc('student_monthly_report', { p_student_id: id, p_month: initialReportMonth })
    : { data: null }

  // 0059: справочники заключения — глобальные, читает любой authenticated;
  // нужны панели для формы и для расшифровки кодов из junction.
  const [{ data: conclusionRows }, { data: formLookupRows }, { data: referralLookupRows }] = await Promise.all([
    supabase.from('speech_conclusions').select('code, name').eq('is_active', true).order('sort'),
    supabase.from('clinical_forms').select('code, name').eq('is_active', true).order('sort'),
    supabase.from('referral_targets').select('code, name').eq('is_active', true).order('sort'),
  ])
  const conclusionLookup = (conclusionRows ?? []).map((r) => ({ code: r.code, name: r.name }))
  const formLookup = (formLookupRows ?? []).map((r) => ({ code: r.code, name: r.name }))
  const referralLookup = (referralLookupRows ?? []).map((r) => ({ code: r.code, name: r.name }))
  const conclusionNameByCode = new Map(conclusionLookup.map((r) => [r.code, r.name]))
  const formNameByCode = new Map(formLookup.map((r) => [r.code, r.name]))
  const referralNameByCode = new Map(referralLookup.map((r) => [r.code, r.name]))

  if (clinicalAllowed && isParent) {
    const [{ data: diagRows }, { data: goalRows }, { data: homeworkRows }, { data: noteRows }] = await Promise.all([
      supabase.rpc('student_diagnostics_brief', { p_student_id: id }),
      supabase.rpc('student_goals_brief', { p_student_id: id }),
      supabase
        .from('homework')
        .select('id, status, free_text, due_on, parent_note, teacher_feedback, assigned_at')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('assigned_at', { ascending: false }),
      // Родителю — только утверждённые резюме, без SOAP и расшифровки (0036 Р4).
      supabase.rpc('student_notes_brief', { p_student_id: id }),
    ])

    clinicalSection = {
      diagnostics: (diagRows ?? []).map((d) => ({
        id: d.id,
        date: d.date,
        conclusion: d.conclusion,
        teacherName: d.teacher_name,
        sounds: {},
        speechAreas: {},
        // Родителю — формулировка заключения из брифа; формы и направления
        // сюда не приходят физически (0059 Р4).
        conclusionName: d.conclusion_name,
        clinicalForms: [],
        referrals: [],
      })),
      goals: (goalRows ?? []).map((g) => ({
        id: g.id,
        title: g.title,
        area: g.area,
        sound: g.sound,
        stageTitle: g.stage_title,
        status: g.status,
        targetDate: g.target_date,
        progress:
          g.last_score != null ? [{ id: g.id, date: g.target_date ?? '', score: g.last_score, note: null }] : [],
        // Родителю RPC (0046) всегда отдаёт trend = null — сознательно,
        // не фильтруется здесь.
        trend: g.trend as GoalTrend | null,
      })),
      stages: [],
      homework: (homeworkRows ?? []).map((h) => ({
        id: h.id,
        status: h.status,
        freeText: h.free_text,
        dueOn: h.due_on,
        parentNote: h.parent_note,
        teacherFeedback: h.teacher_feedback,
        exerciseTitles: [],
      })),
      exercises: [],
      notes: (noteRows ?? []).map((n) => ({
        id: n.id,
        lessonId: n.lesson_id,
        lessonAt: n.lesson_at,
        status: 'approved',
        source: 'text',
        parentSummary: n.parent_summary,
        soap: null,
        rawTranscript: null,
        goalScores: [],
      })),
    }
  } else if (clinicalAllowed) {
    const [
      { data: diagRows },
      { data: goalRows },
      { data: stageRows },
      { data: homeworkRows },
      { data: exerciseRows },
      { data: goalBriefRows },
      { data: noteRows },
    ] = await Promise.all([
      supabase
        .from('diagnostics')
        .select('id, date, conclusion, sounds, speech_areas, teacher_id, conclusion_code')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('date', { ascending: false }),
      supabase
        .from('goals')
        .select('id, title, area, sound, status, target_date, stage_id')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false }),
      supabase.from('goal_stages').select('id, title').is('deleted_at', null).order('sort'),
      supabase
        .from('homework')
        .select('id, status, free_text, due_on, parent_note, teacher_feedback, assigned_at')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('assigned_at', { ascending: false }),
      supabase
        .from('exercise_library')
        .select('id, title, sound')
        .eq('is_active', true)
        .is('deleted_at', null)
        .order('title'),
      // Тренд — источник истины только SQL (0046): читаем его из того же
      // RPC, что и родительская ветка, а не пересчитываем в TS из
      // progressByGoal ниже — иначе окно/пороги могут разъехаться.
      supabase.rpc('student_goals_brief', { p_student_id: id }),
      // Персоналу — вся заметка, включая черновики: RLS сама сузит у
      // teacher по clinical_teacher_sees (0036).
      supabase
        .from('lesson_notes')
        .select('id, lesson_id, status, source, parent_summary, soap, raw_transcript, created_at')
        .eq('student_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false }),
    ])

    const trendByGoal = new Map((goalBriefRows ?? []).map((g) => [g.id, g.trend]))
    const noteIds = (noteRows ?? []).map((n) => n.id)
    const noteLessonIds = [...new Set((noteRows ?? []).map((n) => n.lesson_id))]

    const [{ data: noteLessonRows }, { data: noteScoreRows }] = await Promise.all([
      noteLessonIds.length
        ? supabase.from('lessons').select('id, starts_at').in('id', noteLessonIds)
        : Promise.resolve({ data: [] as { id: string; starts_at: string }[] }),
      noteIds.length
        ? supabase.from('lesson_note_goal_scores').select('note_id, goal_id, score, note').in('note_id', noteIds)
        : Promise.resolve({ data: [] as { note_id: string; goal_id: string; score: number; note: string | null }[] }),
    ])
    const lessonAtById = new Map((noteLessonRows ?? []).map((l) => [l.id, l.starts_at]))
    const goalTitleById = new Map((goalRows ?? []).map((g) => [g.id, g.title]))
    const scoresByNote = new Map<string, NoteEntry['goalScores']>()
    for (const row of noteScoreRows ?? []) {
      const list = scoresByNote.get(row.note_id) ?? []
      list.push({ goalTitle: goalTitleById.get(row.goal_id) ?? 'Цель', score: row.score, note: row.note })
      scoresByNote.set(row.note_id, list)
    }

    const teacherIds = [...new Set((diagRows ?? []).map((d) => d.teacher_id).filter((v): v is string => Boolean(v)))]
    const goalIds = (goalRows ?? []).map((g) => g.id)
    const homeworkIds = (homeworkRows ?? []).map((h) => h.id)

    const [{ data: diagTeacherRows }, { data: progressRows }, { data: homeworkExerciseRows }] = await Promise.all([
      teacherIds.length
        ? supabase.from('teachers').select('id, full_name').in('id', teacherIds)
        : Promise.resolve({ data: [] as { id: string; full_name: string }[] }),
      goalIds.length
        ? supabase
            .from('goal_progress')
            .select('id, goal_id, date, score, note')
            .in('goal_id', goalIds)
            .is('deleted_at', null)
            .order('date', { ascending: false })
        : Promise.resolve({ data: [] as { id: string; goal_id: string; date: string; score: number; note: string | null }[] }),
      homeworkIds.length
        ? supabase.from('homework_exercises').select('homework_id, exercise_id').in('homework_id', homeworkIds).is('deleted_at', null)
        : Promise.resolve({ data: [] as { homework_id: string; exercise_id: string }[] }),
    ])

    const stageTitleById = new Map((stageRows ?? []).map((s) => [s.id, s.title]))
    const teacherNameById = new Map((diagTeacherRows ?? []).map((t) => [t.id, t.full_name]))
    const exerciseTitleById = new Map((exerciseRows ?? []).map((e) => [e.id, e.title]))

    const progressByGoal = new Map<string, GoalEntry['progress']>()
    for (const row of progressRows ?? []) {
      const list = progressByGoal.get(row.goal_id) ?? []
      list.push({ id: row.id, date: row.date, score: row.score, note: row.note })
      progressByGoal.set(row.goal_id, list)
    }

    const exerciseIdsByHomework = new Map<string, string[]>()
    for (const row of homeworkExerciseRows ?? []) {
      const list = exerciseIdsByHomework.get(row.homework_id) ?? []
      list.push(row.exercise_id)
      exerciseIdsByHomework.set(row.homework_id, list)
    }

    // 0059: формы и направления — отдельными запросами по id диагностик,
    // не embed (у junction только составной FK — 0022 Р6). Видимость
    // держит политика через clinical_diagnostic_visible.
    const diagIds = (diagRows ?? []).map((d) => d.id)
    const [{ data: formRows }, { data: referralRows }] = await Promise.all([
      diagIds.length
        ? supabase
            .from('diagnostic_clinical_forms')
            .select('diagnostic_id, form_code')
            .in('diagnostic_id', diagIds)
            .is('deleted_at', null)
        : Promise.resolve({ data: [] as { diagnostic_id: string; form_code: string }[] }),
      diagIds.length
        ? supabase
            .from('diagnostic_referrals')
            .select('diagnostic_id, target_code, note')
            .in('diagnostic_id', diagIds)
            .is('deleted_at', null)
        : Promise.resolve({ data: [] as { diagnostic_id: string; target_code: string; note: string | null }[] }),
    ])
    const formsByDiag = new Map<string, string[]>()
    for (const row of formRows ?? []) {
      const list = formsByDiag.get(row.diagnostic_id) ?? []
      list.push(formNameByCode.get(row.form_code) ?? row.form_code)
      formsByDiag.set(row.diagnostic_id, list)
    }
    const referralsByDiag = new Map<string, { target: string; note: string | null }[]>()
    for (const row of referralRows ?? []) {
      const list = referralsByDiag.get(row.diagnostic_id) ?? []
      list.push({ target: referralNameByCode.get(row.target_code) ?? row.target_code, note: row.note })
      referralsByDiag.set(row.diagnostic_id, list)
    }

    clinicalSection = {
      diagnostics: (diagRows ?? []).map((d) => ({
        id: d.id,
        date: d.date,
        conclusion: d.conclusion,
        teacherName: d.teacher_id ? (teacherNameById.get(d.teacher_id) ?? null) : null,
        sounds: (d.sounds ?? {}) as Record<string, string>,
        speechAreas: (d.speech_areas ?? {}) as Record<string, number>,
        conclusionName: d.conclusion_code ? (conclusionNameByCode.get(d.conclusion_code) ?? null) : null,
        clinicalForms: formsByDiag.get(d.id) ?? [],
        referrals: referralsByDiag.get(d.id) ?? [],
      })),
      goals: (goalRows ?? []).map((g) => ({
        id: g.id,
        title: g.title,
        area: g.area,
        sound: g.sound,
        stageTitle: stageTitleById.get(g.stage_id) ?? null,
        status: g.status,
        targetDate: g.target_date,
        progress: progressByGoal.get(g.id) ?? [],
        trend: (trendByGoal.get(g.id) ?? null) as GoalTrend | null,
      })),
      stages: (stageRows ?? []).map((s) => ({ id: s.id, title: s.title })),
      homework: (homeworkRows ?? []).map((h) => ({
        id: h.id,
        status: h.status,
        freeText: h.free_text,
        dueOn: h.due_on,
        parentNote: h.parent_note,
        teacherFeedback: h.teacher_feedback,
        exerciseTitles: (exerciseIdsByHomework.get(h.id) ?? [])
          .map((exerciseId) => exerciseTitleById.get(exerciseId))
          .filter((t): t is string => Boolean(t)),
      })),
      exercises: (exerciseRows ?? []).map((e) => ({ id: e.id, title: e.title, sound: e.sound })),
      notes: (noteRows ?? []).map((n) => ({
        id: n.id,
        lessonId: n.lesson_id,
        lessonAt: lessonAtById.get(n.lesson_id) ?? n.created_at,
        status: n.status,
        source: n.source,
        parentSummary: n.parent_summary,
        soap: (n.soap ?? null) as NoteSoap | null,
        rawTranscript: n.raw_transcript,
        goalScores: scoresByNote.get(n.id) ?? [],
      })),
    }
  }

  if (showAnamnesis) {
    const { data: anamnesisRow } = await supabase
      .from('student_anamnesis')
      .select(
        'updated_at, collected_at, pregnancy_number, birth_number, pregnancy_course, birth_course, apgar_note, early_development, cooing_age, babbling_age, first_words_age, phrase_speech_age, illnesses_injuries, heredity, upbringing_conditions, hearing_note, vision_note, notes',
      )
      .eq('student_id', id)
      .maybeSingle()

    if (anamnesisRow) {
      anamnesis = {
        updatedAt: anamnesisRow.updated_at,
        collectedAt: anamnesisRow.collected_at,
        pregnancyNumber: anamnesisRow.pregnancy_number,
        birthNumber: anamnesisRow.birth_number,
        pregnancyCourse: anamnesisRow.pregnancy_course,
        birthCourse: anamnesisRow.birth_course,
        apgarNote: anamnesisRow.apgar_note,
        earlyDevelopment: anamnesisRow.early_development,
        cooingAge: anamnesisRow.cooing_age,
        babblingAge: anamnesisRow.babbling_age,
        firstWordsAge: anamnesisRow.first_words_age,
        phraseSpeechAge: anamnesisRow.phrase_speech_age,
        illnessesInjuries: anamnesisRow.illnesses_injuries,
        heredity: anamnesisRow.heredity,
        upbringingConditions: anamnesisRow.upbringing_conditions,
        hearingNote: anamnesisRow.hearing_note,
        visionNote: anamnesisRow.vision_note,
        notes: anamnesisRow.notes,
      }
    }
  }

  if (showArticulation) {
    const { data: articulationRow } = await supabase
      .from('student_articulation')
      .select(
        'updated_at, collected_at, lips_structure, lips_mobility, teeth, bite, hard_palate, soft_palate, tongue_structure, tongue_mobility, frenulum, notes',
      )
      .eq('student_id', id)
      .maybeSingle()

    if (articulationRow) {
      articulation = {
        updatedAt: articulationRow.updated_at,
        collectedAt: articulationRow.collected_at,
        lipsStructure: articulationRow.lips_structure,
        lipsMobility: articulationRow.lips_mobility,
        teeth: articulationRow.teeth,
        bite: articulationRow.bite,
        hardPalate: articulationRow.hard_palate,
        softPalate: articulationRow.soft_palate,
        tongueStructure: articulationRow.tongue_structure,
        tongueMobility: articulationRow.tongue_mobility,
        frenulum: articulationRow.frenulum,
        notes: articulationRow.notes,
      }
    }
  }

  if (showSyllableAssessments) {
    const { data: syllableRows } = await supabase
      .from('syllable_assessments')
      .select('id, date, updated_at, teacher_id, affected_classes, error_types, conclusion')
      .eq('student_id', id)
      .is('deleted_at', null)
      .order('date', { ascending: false })

    const syllableTeacherIds = [
      ...new Set((syllableRows ?? []).map((s) => s.teacher_id).filter((v): v is string => Boolean(v))),
    ]
    const { data: syllableTeacherRows } = syllableTeacherIds.length
      ? await supabase.from('teachers').select('id, full_name').in('id', syllableTeacherIds)
      : { data: [] as { id: string; full_name: string }[] }
    const syllableTeacherNameById = new Map((syllableTeacherRows ?? []).map((t) => [t.id, t.full_name]))

    syllableAssessments = (syllableRows ?? []).map((s) => ({
      id: s.id,
      date: s.date,
      updatedAt: s.updated_at,
      teacherName: s.teacher_id ? (syllableTeacherNameById.get(s.teacher_id) ?? null) : null,
      affectedClasses: s.affected_classes ?? [],
      errorTypes: s.error_types ?? [],
      conclusion: s.conclusion,
    }))
  }

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
        {(isAdmin || isRegistrar) && 'funnel_stage' in base && base.funnel_stage ? (
          <div className="mt-2">
            <FunnelStageWidget studentId={student.id} stage={base.funnel_stage as FunnelStage} />
          </div>
        ) : null}
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
            {payer ? 'Контакты для связи с семьёй.' : 'Контакты видны администратору центра.'}
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
                {isAdmin ? (
                  <Link
                    href={`/app/payers/${payer.id}`}
                    className={buttonVariants({ variant: 'ghost', size: 'sm' })}
                  >
                    Карточка плательщика
                  </Link>
                ) : null}
              </div>
            </>
          ) : null}
        </CardContent>
      </Card>

      {subscriptionsSection ? (
        <Card>
          <CardHeader>
            <CardTitle>{subscriptionsSection.canManage ? 'Абонементы и посещения' : 'Абонементы'}</CardTitle>
            <CardDescription>
              {subscriptionsSection.canManage
                ? 'Продажа, заморозка, возврат — доступны только администратору.'
                : 'Оплачено, состояние и график рассрочки — те же данные, что видит центр.'}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <SubscriptionsPanel studentId={id} {...subscriptionsSection} />
          </CardContent>
        </Card>
      ) : subscriptionBadge ? (
        <Card>
          <CardHeader>
            <CardTitle>Абонемент</CardTitle>
          </CardHeader>
          <CardContent>
            <span
              className={cn(
                'rounded px-2 py-0.5 text-sm font-medium',
                subscriptionBadge === 'нет' ? 'bg-destructive/10 text-destructive' : 'bg-muted text-foreground',
              )}
            >
              {subscriptionBadge}
            </span>
          </CardContent>
        </Card>
      ) : null}

      {showAnamnesis ? (
        <Card>
          <CardHeader>
            <CardTitle>Анамнез</CardTitle>
            <CardDescription>История до первого приёма. Родителю не показывается.</CardDescription>
          </CardHeader>
          <CardContent>
            <AnamnesisPanel studentId={id} entry={anamnesis} canWrite={canWriteClinical} />
          </CardContent>
        </Card>
      ) : null}

      {showArticulation ? (
        <Card>
          <CardHeader>
            <CardTitle>Артикуляционный аппарат</CardTitle>
            <CardDescription>Строение и подвижность. Родителю не показывается.</CardDescription>
          </CardHeader>
          <CardContent>
            <ArticulationPanel studentId={id} entry={articulation} canWrite={canWriteClinical} />
          </CardContent>
        </Card>
      ) : null}

      {showSyllableAssessments ? (
        <Card>
          <CardHeader>
            <CardTitle>Слоговая структура</CardTitle>
            <CardDescription>История обследований. Родителю не показывается.</CardDescription>
          </CardHeader>
          <CardContent>
            <SyllableAssessmentPanel studentId={id} entries={syllableAssessments} canWrite={canWriteClinical} />
          </CardContent>
        </Card>
      ) : null}

      {clinicalSection ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Диагностика</CardTitle>
              <CardDescription>Карта звуков и речевые области.</CardDescription>
            </CardHeader>
            <CardContent>
              <DiagnosticsPanel
                studentId={id}
                entries={clinicalSection.diagnostics}
                canWrite={canWriteClinical}
                conclusions={conclusionLookup}
                forms={formLookup}
                referralTargets={referralLookup}
              />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Цели</CardTitle>
              <CardDescription>Прогресс по звукам и этапам работы.</CardDescription>
            </CardHeader>
            <CardContent>
              <GoalsPanel
                studentId={id}
                goals={clinicalSection.goals}
                stages={clinicalSection.stages}
                canWrite={canWriteClinical}
              />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Домашние задания</CardTitle>
              <CardDescription>Выдача, сдача и фидбек.</CardDescription>
            </CardHeader>
            <CardContent>
              <HomeworkPanel
                studentId={id}
                homework={clinicalSection.homework}
                exercises={clinicalSection.exercises}
                canWrite={canWriteClinical}
              />
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>Заметки занятий</CardTitle>
              <CardDescription>
                {isParent
                  ? 'Резюме занятий от специалиста.'
                  : 'Черновики из голосовых и текстовые заметки. Родитель видит резюме только после утверждения.'}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <NotesPanel
                studentId={id}
                notes={clinicalSection.notes}
                canWrite={canWriteClinical}
                timeZone={clinicalTimeZone}
              />
            </CardContent>
          </Card>

          {initialReportMonth ? (
            <Card>
              <CardHeader>
                <CardTitle>Отчёт за месяц</CardTitle>
                <CardDescription>
                  {isParent
                    ? 'Посещения, динамика целей и резюме занятий за месяц.'
                    : 'Собирается из посещений, оценок целей и утверждённых резюме. Родителю уходит в Telegram.'}
                </CardDescription>
              </CardHeader>
              <CardContent>
                <MonthlyReportPanel
                  studentId={id}
                  months={reportMonths}
                  initialMonth={initialReportMonth}
                  initialReport={(initialReport as unknown as MonthlyReport | null) ?? null}
                  canSend={canWriteClinical}
                  canResend={isAdmin}
                  timeZone={clinicalTimeZone}
                />
              </CardContent>
            </Card>
          ) : null}
        </>
      ) : null}

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
