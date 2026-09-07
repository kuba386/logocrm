import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'
import type { Database } from '@logocrm/db'
import { supabaseEnv } from '@/lib/env'

const PUBLIC_PATHS = ['/login', '/auth', '/error', '/invite']


/**
 * Обновляет сессию на каждом запросе и уводит неавторизованных на /login.
 * Между createServerClient и getUser() не должно быть никакой логики —
 * иначе пользователь может «залипнуть» с протухшим токеном.
 */
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })
  const { url, anonKey } = supabaseEnv()

  const supabase = createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value)
        }
        supabaseResponse = NextResponse.next({ request })
        for (const { name, value, options } of cookiesToSet) {
          supabaseResponse.cookies.set(name, value, options)
        }
      },
    },
  })

  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { pathname } = request.nextUrl
  const isPublic = PUBLIC_PATHS.some((path) => pathname === path || pathname.startsWith(`${path}/`))

  if (!user && !isPublic) {
    const loginUrl = request.nextUrl.clone()
    loginUrl.pathname = '/login'
    loginUrl.searchParams.set('next', pathname)
    return NextResponse.redirect(loginUrl)
  }

  if (user && pathname === '/login') {
    const appUrl = request.nextUrl.clone()
    appUrl.pathname = '/app'
    appUrl.search = ''
    return NextResponse.redirect(appUrl)
  }

  return supabaseResponse
}
