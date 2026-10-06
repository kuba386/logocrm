import { Skeleton } from '@/components/ui/skeleton'

// Пока сервер собирает страницу, шапка и меню уже на месте, а вместо
// содержимого — силуэт: клик по меню отзывается сразу, а не «экран стоит»
// (UX-аудит, пакет 8). Один общий силуэт на все разделы: заголовок, строка
// фильтров, таблица — так устроено большинство страниц /app.
export default function AppLoading() {
  return (
    <div role="status" className="space-y-6">
      <span className="sr-only">Загрузка…</span>
      <div className="space-y-2">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="h-4 w-72 max-w-full" />
      </div>
      <div className="flex gap-2">
        <Skeleton className="h-10 w-40" />
        <Skeleton className="h-10 w-32" />
      </div>
      <div className="space-y-2 rounded-lg border border-border p-4">
        {Array.from({ length: 6 }, (_, i) => (
          <Skeleton key={i} className="h-10 w-full" />
        ))}
      </div>
    </div>
  )
}
