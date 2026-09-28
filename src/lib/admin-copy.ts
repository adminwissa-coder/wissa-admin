/** Presentation-only message cleanup; original errors remain in application state. */
export function adminMessage(value: unknown): string {
  const message = String(value ?? '').trim()
  if (!message) return ''
  if (/jwt|session.*expired|invalid.*token/i.test(message)) return 'Tu sesión venció. Inicia sesión nuevamente.'
  if (/permission denied|row.level security|not authorized|unauthorized/i.test(message)) return 'No tienes permiso para realizar esta acción.'
  if (/failed to fetch|network|fetch failed|timeout/i.test(message)) return 'No se pudo conectar. Revisa tu conexión e inténtalo nuevamente.'
  if (/supabase|postgres|sql|rpc|schema|pgrst|constraint|invalid input|duplicate key|null value|syntax error|violates|TypeError|column|relation|function|bucket|storage|backend|\bAPI\b|\bJSON\b|\bRLS\b|\bV\d+\.\d+|[a-z]+_[a-z]+/i.test(message)) return 'No se pudo completar la operación. Inténtalo nuevamente o contacta a soporte.'
  return message
}

export function isInternalDetail(key: string): boolean {
  return /(^__|_id$|_bucket$|_path$|_token$|_version$|_snapshot$|_payload$|_response$)/.test(key) || ['metadata', 'service_details', 'pricing', 'source', 'response', 'error_message'].includes(key)
}
