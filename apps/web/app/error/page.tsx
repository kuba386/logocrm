import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'

export default function ErrorPage() {
  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <div className="max-w-md space-y-4 text-center">
        <h1 className="page-title">Что-то пошло не так</h1>
        <p className="text-sm text-muted-foreground">
          Ссылка из письма не сработала. Так бывает, если открыть не последнее письмо или открыть его в
          другом браузере, чем тот, где вы регистрировались.
        </p>
        <p className="text-sm text-muted-foreground">
          Если почта уже подтверждена — просто войдите с паролем. Если нет — на странице входа нажмите
          «Войти по ссылке из письма», придёт новое письмо.
        </p>
        <Link href="/login" className={buttonVariants()}>
          На страницу входа
        </Link>
      </div>
    </main>
  )
}
