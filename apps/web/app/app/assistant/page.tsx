import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { t } from '@/lib/messages'
import { isAssistantConfigured } from '@/lib/openai'
import { FormNotice } from '@/components/ui/alert'
import { AssistantForm } from './assistant-form'

export const metadata = { title: 'Ассистент — LogoCRM' }

/**
 * AI-ассистент (0064): одна страница для всех сотрудников; родителю —
 * редирект (косметика, гейт — assistant_begin в SQL, Р14).
 */
export default async function AssistantPage() {
  const supabase = await createClient()
  const { data: role } = await supabase.rpc('my_role')
  if (!role) redirect('/select-center')
  if (role === 'parent') redirect('/app')

  const configured = isAssistantConfigured()
  const { data: quotaJson } = configured ? await supabase.rpc('assistant_quota') : { data: null }
  const q = quotaJson as { used?: number; limit?: number } | null
  const quota = q && typeof q.used === 'number' && typeof q.limit === 'number' ? { used: q.used, limit: q.limit } : undefined

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t('assistant', 'title')}</h1>
        <p className="text-sm text-muted-foreground">{t('assistant', 'subtitle')}</p>
      </div>
      {configured ? <AssistantForm quota={quota} /> : <FormNotice message={t('assistant', 'notConfigured')} />}
    </div>
  )
}
