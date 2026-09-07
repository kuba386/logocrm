import Link from 'next/link'
import { redirect } from 'next/navigation'
import { formatKgPhone, whatsappNumber } from '@logocrm/core'
import { createClient } from '@/lib/supabase/server'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { buttonVariants } from '@/components/ui/button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'

export const metadata = { title: 'Плательщики — LogoCRM' }

export default async function PayersPage() {
  const supabase = await createClient()

  const {
    data: { user },
  } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: role } = await supabase.rpc('my_role')
  if (role !== 'owner' && role !== 'admin') redirect('/app')

  const { data: payers } = await supabase
    .from('payers_with_stats')
    .select('*')
    .order('full_name')

  const rows = (payers ?? []).filter((row) => row.id !== null)

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Плательщики</h1>
        <p className="text-sm text-muted-foreground">
          Родители и опекуны. На плательщике живут контакты, оплаты и долги — не на ребёнке.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Список</CardTitle>
          <CardDescription>Всего: {rows.length}</CardDescription>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              Плательщики появятся, когда добавите первого ученика.
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>ФИО</TableHead>
                  <TableHead>Кем приходится</TableHead>
                  <TableHead>Телефон</TableHead>
                  <TableHead>Детей</TableHead>
                  <TableHead className="text-right">Связь</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {rows.map((payer) => {
                  const wa = payer.phone ? whatsappNumber(payer.phone) : null
                  return (
                    <TableRow key={payer.id}>
                      <TableCell className="font-medium">
                        <Link href={`/app/payers/${payer.id}`} className="hover:underline">
                          {payer.full_name}
                        </Link>
                      </TableCell>
                      <TableCell className="text-muted-foreground">{payer.relation ?? '—'}</TableCell>
                      <TableCell>{formatKgPhone(payer.phone)}</TableCell>
                      <TableCell>{payer.children_count ?? 0}</TableCell>
                      <TableCell>
                        <div className="flex justify-end gap-2">
                          <a
                            href={`tel:${payer.phone}`}
                            className={buttonVariants({ variant: 'outline', size: 'sm' })}
                          >
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
                        </div>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
