import type { MetadataRoute } from 'next'
import { siteUrl } from '@/lib/env'

/**
 * Индексировать — лендинг и публичные страницы записи центров. Всё служебное
 * закрыто: приложение за входом, пульт платформы, вход, сброс пароля и
 * особенно ссылки-приглашения (/invite/<токен> — это ключ доступа к центру).
 */
export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: '*',
      allow: ['/', '/book/'],
      disallow: ['/app', '/admin', '/api', '/invite', '/login', '/onboarding', '/select-center', '/access-revoked', '/reset-password', '/auth', '/error'],
    },
    sitemap: `${siteUrl()}/sitemap.xml`,
  }
}
