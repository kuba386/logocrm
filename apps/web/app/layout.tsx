import type { Metadata } from 'next'
import { display, text } from './fonts'
import './globals.css'

export const metadata: Metadata = {
  title: 'LogoCRM',
  description: 'CRM для логопедических центров',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ru" className={`${display.variable} ${text.variable}`}>
      <body>{children}</body>
    </html>
  )
}
