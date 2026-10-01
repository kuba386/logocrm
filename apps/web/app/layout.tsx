import type { Metadata } from 'next'
// Шрифты из npm, а не next/font/google: тот скачивает их с Google Fonts во
// время сборки и на Vercel время от времени падал на пустом ответе.
import '@fontsource-variable/golos-text'
import '@fontsource-variable/unbounded'
import './globals.css'

export const metadata: Metadata = {
  title: 'LogoCRM',
  description: 'CRM для логопедических центров',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  )
}
