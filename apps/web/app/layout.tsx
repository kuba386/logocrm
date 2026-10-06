import type { Metadata } from 'next'
// Шрифты из npm, а не next/font/google: тот скачивает их с Google Fonts во
// время сборки и на Vercel время от времени падал на пустом ответе.
import '@fontsource-variable/golos-text'
import '@fontsource-variable/unbounded'
import './globals.css'
import { siteUrl } from '@/lib/env'

// metadataBase — чтобы ссылки превью (Open Graph) были абсолютными: без него
// Telegram и WhatsApp показывали ссылку на лендинг голой строкой.
export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: 'LogoCRM',
  description: 'CRM для логопедических центров',
  applicationName: 'LogoCRM',
  openGraph: {
    type: 'website',
    locale: 'ru_RU',
    siteName: 'LogoCRM',
    title: 'LogoCRM — программа для логопедического центра',
    description: 'Расписание без накладок, абонементы и долги, цели по звукам и отчёты родителям в Telegram. 14 дней бесплатно.',
  },
  twitter: { card: 'summary' },
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  )
}
