/** Ссылка на квитанцию платежа (/app/finance/receipt/[id]) с возвратом на страницу, откуда её открыли. */
export function receiptHref(paymentId: string, back?: string): string {
  return `/app/finance/receipt/${paymentId}${back ? `?back=${encodeURIComponent(back)}` : ''}`
}
