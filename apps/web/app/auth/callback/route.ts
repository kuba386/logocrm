import { NextResponse, type NextRequest } from 'next/server'
import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { acceptInvitation } from '@/app/invite/[token]/actions'
import { INVITE_COOKIE } from '@/lib/invite'

/**
 * Обмен кода из письма на сессию. Если пользователь пришёл по приглашению,
 * токен лежит в httpOnly-куке — принимаем приглашение здесь же.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl
  const code = searchParams.get('code')
  const next = searchParams.get('next') ?? '/app'

  if (!code) {
    return NextResponse.redirect(`${origin}/error`)
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)

  if (error) {
    return NextResponse.redirect(`${origin}/error`)
  }

  const store = await cookies()
  const inviteToken = store.get(INVITE_COOKIE)?.value

  if (inviteToken) {
    const accepted = await acceptInvitation(inviteToken)
    if (accepted.error) {
      // Сессия уже есть, но приглашение не принято — назад на страницу
      // приглашения: она покажет «Принять» под этим аккаунтом, и причина
      // отказа (истекла, уже использована, лимит) будет видна, а не молча
      // потеряна на выборе центра (ревью 6.10.2026).
      return NextResponse.redirect(`${origin}/invite/${encodeURIComponent(inviteToken)}`)
    }
  }

  return NextResponse.redirect(`${origin}${next}`)
}
