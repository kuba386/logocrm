import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export const metadata = { title: 'Дашборд — LogoCRM' }

export default function DashboardPage() {
  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold tracking-tight">Дашборд</h1>

      <Card>
        <CardHeader>
          <CardTitle>Здесь пока пусто</CardTitle>
          <CardDescription>
            Заглушка. Дальше сюда придут занятия, ученики, абонементы и оплаты.
          </CardDescription>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">
          Каркас готов: тенант, роли, RLS, аудит и outbox уже работают.
        </CardContent>
      </Card>
    </div>
  )
}
