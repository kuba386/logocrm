import { Golos_Text, Unbounded } from 'next/font/google'

export const display = Unbounded({
  subsets: ['cyrillic', 'latin'],
  weight: ['500', '700'],
  variable: '--font-display',
  display: 'swap',
})

export const text = Golos_Text({
  subsets: ['cyrillic', 'latin'],
  weight: ['400', '500'],
  variable: '--font-text',
  display: 'swap',
})
