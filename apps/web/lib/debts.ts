export type DebtProblem = { label: string; amount: number | null; tone: 'danger' | 'warning' }

// Три разных долга не складываются в один (docs/Database.md, «Два слова,
// два определения»): за занятия без абонемента, перерасход по абонементу и
// просрочка оплаты САМОГО абонемента (0070) — разные деньги, разные причины
// написать родителю. «Остаток исчерпан» — не долг, а сигнал «пора продлить»,
// показывается только когда денежных проблем нет вовсе. Суммы и признаки —
// из student_debt_problems() (0076), здесь только подписи.
export function debtProblems(row: {
  debtTiyin: number
  overdrawnTiyin: number
  subscriptionOverdueTiyin: number
}): DebtProblem[] {
  const list: DebtProblem[] = []
  if (row.debtTiyin > 0) list.push({ label: 'Долг за занятия', amount: row.debtTiyin, tone: 'danger' })
  if (row.overdrawnTiyin > 0) list.push({ label: 'Перерасход', amount: row.overdrawnTiyin, tone: 'danger' })
  if (row.subscriptionOverdueTiyin > 0) {
    list.push({ label: 'Просрочен платёж за абонемент', amount: row.subscriptionOverdueTiyin, tone: 'danger' })
  }
  if (list.length === 0) list.push({ label: 'Остаток исчерпан', amount: null, tone: 'warning' })
  return list
}
