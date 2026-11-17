import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL?.trim()
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()

export const supabaseConfigured = Boolean(url && anonKey)
export const supabase = supabaseConfigured
  ? createClient(url!, anonKey!, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    })
  : null

export function publicAppUrl() {
  const configured = import.meta.env.VITE_PUBLIC_APP_URL?.trim()
  const candidate = configured || window.location.origin
  try {
    const parsed = new URL(candidate)
    if (parsed.protocol === 'https:' && !['localhost', '127.0.0.1'].includes(parsed.hostname) && !parsed.hostname.endsWith('.localhost')) return parsed.origin
  } catch { /* an invalid or local value cannot be used in a public invitation */ }
  return null
}
