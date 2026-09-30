import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { statusLabel, studentAge } from '@/lib/students'
import { isFrontDesk } from '@/lib/roles'
import { PageHeader } from '@/components/ui/page-header'
import { StatusBadge } from '@/components/ui/status-badge'
import { AddStudentDialog } from '@/app/app/students/add-student-dialog'

export const metadata = { title: 'Плательщик — LogoCRM' }

export default async function PayerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  // Гейт — RLS, не роль в коде (0062): карточку читают те, кому payers
  // читаемы (owner/admin, registrar, родитель — свою); остальным строка не
  // придёт → notFound. Иначе поиск отдавал бы строки, которые нельзя открыть.
  const { data: role } = await supabase.rpc('my_role')
  const frontDesk = isFrontDesk(role)

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
    // Бейдж и действия стойки — только стойке; родитель видит свою карточку
    // без кнопок (RLS пустила бы его к строке, а RPC отказал бы).
    frontDesk ? supabase.rpc('payer_telegram_linked', { p_payer_id: id }) : Promise.resolve({ data: null }),
  ])

  const wa = whatsappNumber(payer.phone)

  return (
    <div className="space-y-6">
      <PageHeader
        back={frontDesk ? { href: '/app/payers', label: 'Все плательщики' } : undefined}
        title={payer.full_name}
        aside={
          frontDesk ? (
            <StatusBadge tone={telegramLinked ? 'success' : 'neutral'}>
              {telegramLinked ? 'Telegram привязан' : 'Telegram не привязан'}
            </StatusBadge>
          ) : null
        }
        description={[payer.relation ?? 'родитель', formatKgPhone(payer.phone), payer.email].filter(Boolean).join(', ')}
        actions={
          frontDesk ? (
            <>
              <a href={`tel:${payer.phone}`} className={buttonVariants({ variant: 'outline', size: 'sm' })}>
                Позвонить
              </a>
              {wa ? (
                <a
                  href={`https://wa.me/${wa}`}
                  target="_blank"
                  rel="noreferrer"
                  className={buttonVariants({ variant: 'outline', size: 'sm' })}
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
                  className={buttonVariants({ variant: 'outline', size: 'sm' })}
                >
                  Пригласить в бот
                </a>
              ) : null}
              <AddStudentDialog
                teachers={(teachers ?? []).map((t) => ({ id: t.id, fullName: t.full_name }))}
                presetPayer={{ id: payer.id, fullName: payer.full_name }}
                label="Добавить ребёнка"
              />
            </>
          ) : null
        }
      />

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
                      {studentAge(child.birth_date)}, {statusLabel(child.status).toLowerCase()}
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

      {/* Заметка стойки о родителе — не родителю. */}
      {frontDesk && payer.notes ? (
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
