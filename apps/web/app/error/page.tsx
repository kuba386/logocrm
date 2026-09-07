import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'

export default function ErrorPage() {
  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="max-w-md space-y-4 text-center">
        <h1 className="text-2xl font-semibold">Что-то пошло не так</h1>
        <p className="text-sm text-muted-foreground">
          Ссылка недействительна или срок её действия истёк. Попробуйте войти ещё раз.
        </p>
        <Link href="/login" className={buttonVariants()}>
          На страницу входа
        </Link>
      </div>
    </main>
  )
}
