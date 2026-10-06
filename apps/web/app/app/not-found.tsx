import Link from 'next/link'
import { buttonVariants } from '@/components/ui/button'

// notFound() со страницы внутри /app (удалённый ученик, чужая ссылка):
// шапка и меню остаются, есть выход на дашборд. Раньше — английская
// «This page could not be found» без навигации.
export default function AppNotFound() {
  return (
    <div className="flex justify-center py-10">
      <div className="w-full max-w-md space-y-4 text-center">
        <h1 className="page-title">Не нашли такую страницу</h1>
        <p className="text-sm text-muted-foreground">
          Возможно, запись удалили или ссылка устарела. Проверьте адрес или вернитесь на дашборд.
        </p>
        <Link href="/app" className={buttonVariants()}>
          На дашборд
        </Link>
      </div>
    </div>
  )
}
