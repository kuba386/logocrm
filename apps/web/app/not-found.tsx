import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'

export const metadata = { title: 'Страница не найдена — LogoCRM' }

// Адрес, которого нет вовсе. Внутри /app свой not-found — с меню.
export default function NotFound() {
  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-md space-y-4 text-center">
        <p className="font-display text-5xl font-medium tabular-nums text-muted-foreground">404</p>
        <h1 className="page-title">Не нашли такую страницу</h1>
        <p className="text-sm text-muted-foreground">Проверьте адрес — или начните с главной.</p>
        <div className="flex flex-col gap-2 sm:flex-row sm:justify-center">
          <Link href="/" className={buttonVariants({ variant: 'outline' })}>
            На главную
          </Link>
          <Link href="/app" className={buttonVariants()}>
            Войти в CRM
          </Link>
        </div>
      </div>
    </main>
  )
}
