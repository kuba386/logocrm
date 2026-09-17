import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { statusLabel, studentAge } from '@/lib/students'
import { cn } from '@/lib/utils'
import { AddStudentDialog } from '@/app/app/students/add-student-dialog'

export const metadata = { title: 'Плательщик — LogoCRM' }

export default async function PayerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: payer } = await supabase
    .from('payers')
    .select('id, full_name, phone, phone_alt, email, relation, notes')
    .eq('id', id)
    .is('deleted_at', null)
    .maybeSingle()

  if (!payer) notFound()

  // Бейдж — узкой функцией, а не чтением telegram_accounts: таблица привязок
  // стойке не положена, ответ нужен один — «да/нет» (0033).
  const [{ data: children }, { data: teachers }, { data: telegramLinked }] = await Promise.all([
    supabase
      .from('students')
      .select('id, full_name, birth_date, status')
      .eq('payer_id', id)
      .is('deleted_at', null)
      .order('full_name'),
    supabase
      .from('teachers')
      .select('id, full_name')
      .is('deleted_at', null)
      .eq('is_active', true)
      .order('full_name'),
    supabase.rpc('payer_telegram_linked', { p_payer_id: id }),
  ])

  const wa = whatsappNumber(payer.phone)

  return (
    <div className="space-y-6">
      <div>
        <Link href="/app/payers" className="text-sm text-muted-foreground hover:underline">
          ← Все плательщики
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h1 className="text-2xl font-semibold tracking-tight">{payer.full_name}</h1>
          <span
            className={cn(
              'rounded-full px-2 py-0.5 text-xs',
              telegramLinked ? 'bg-accent text-accent-foreground' : 'bg-muted text-muted-foreground',
            )}
          >
            {telegramLinked ? 'Telegram привязан' : 'Telegram не привязан'}
          </span>
        </div>
        <p className="text-sm text-muted-foreground">
          {payer.relation ?? 'родитель'} · {formatKgPhone(payer.phone)}
          {payer.email ? ` · ${payer.email}` : ''}
        </p>
      </div>

      <div className="flex flex-wrap gap-2">
        <a href={`tel:${payer.phone}`} className={buttonVariants({ variant: 'outline' })}>
          Позвонить
        </a>
        {wa ? (
          <a
            href={`https://wa.me/${wa}`}
            target="_blank"
            rel="noreferrer"
            className={buttonVariants({ variant: 'outline' })}
          >
            WhatsApp
          </a>
        ) : null}
        {!telegramLinked && wa ? (
          <a
            href={`https://wa.me/${wa}?text=${encodeURIComponent(
              'Здравствуйте! Чтобы получать напоминания о занятиях и остаток абонемента, привяжите Telegram: откройте LogoCRM → раздел Telegram → «Получить код».',
            )}`}
            target="_blank"
            rel="noreferrer"
            className={buttonVariants({ variant: 'outline' })}
          >
            Пригласить в бот
          </a>
        ) : null}
        <AddStudentDialog
          teachers={(teachers ?? []).map((t) => ({ id: t.id, fullName: t.full_name }))}
          presetPayer={{ id: payer.id, fullName: payer.full_name }}
          label="Добавить ребёнка"
        />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Дети</CardTitle>
          <CardDescription>Все, за кого платит этот человек.</CardDescription>
        </CardHeader>
        <CardContent>
          {children && children.length > 0 ? (
            <ul className="space-y-2">
              {children.map((child) => (
                <li key={child.id} className="flex items-center justify-between gap-4 rounded-md border border-border p-3">
                  <div>
                    <Link href={`/app/students/${child.id}`} className="font-medium hover:underline">
                      {child.full_name}
                    </Link>
                    <p className="text-sm text-muted-foreground">
                      {studentAge(child.birth_date)} · {statusLabel(child.status)}
                    </p>
                  </div>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">Детей пока нет.</p>
          )}
        </CardContent>
      </Card>

      {payer.notes ? (
        <Card>
          <CardHeader>
            <CardTitle>Заметка</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="whitespace-pre-line text-sm">{payer.notes}</p>
          </CardContent>
        </Card>
      ) : null}
    </div>
  )
}
