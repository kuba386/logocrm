import type { Metadata, Viewport } from 'next'
// Шрифты из npm, а не next/font/google: тот скачивает их с Google Fonts во
// время сборки и на Vercel время от времени падал на пустом ответе.
import '@fontsource-variable/golos-text'
import '@fontsource-variable/unbounded'
import './globals.css'
import { siteUrl } from '@/lib/env'
import { RegisterServiceWorker } from '@/components/pwa/register-sw'

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
  // Установленное на iPhone приложение (PWA): без строки Safari, имя под иконкой.
  // Манифест подключает app/manifest.ts, иконку для iOS — app/apple-icon.png.
  appleWebApp: { capable: true, title: 'LogoCRM', statusBarStyle: 'default' },
  formatDetection: { telephone: false },
}

export const viewport: Viewport = {
  themeColor: '#0F7466',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru">
      <body>
        {children}
        <RegisterServiceWorker />
      </body>
    </html>
  )
}
