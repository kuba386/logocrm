import { SettingsNav } from './settings-nav'

/** Роль проверяет каждая страница сама (redirect на /app) — здесь только подменю. */
export default function SettingsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="space-y-6">
      <SettingsNav />
      {children}
    </div>
  )
}
