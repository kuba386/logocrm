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
      // Сессия уже есть — пусть человек попадёт внутрь, а не в тупик.
      return NextResponse.redirect(`${origin}/select-center`)
    }
  }

  return NextResponse.redirect(`${origin}${next}`)
}
