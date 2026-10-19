'use client'

import { createContext, useContext } from 'react'
import { centerTerms, type CenterKind, type CenterTerms } from '@logocrm/core'

const TermsContext = createContext<CenterTerms>(centerTerms('speech'))

/** Слова интерфейса по типу центра (0104) для клиентских компонентов; тип приходит из layout. */
export function CenterTermsProvider({ kind, children }: { kind: CenterKind; children: React.ReactNode }) {
  return <TermsContext.Provider value={centerTerms(kind)}>{children}</TermsContext.Provider>
}

export function useTerms(): CenterTerms {
  return useContext(TermsContext)
}
