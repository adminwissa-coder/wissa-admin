'use client'

import { adminMessage } from '@/lib/admin-copy'

import { useCallback, useEffect, useState } from 'react'
import { BadgeDollarSign, Gift, Percent, RefreshCw, Search, TicketCheck, Users } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { formatPanamaDateTime, money } from '@/lib/utils'

type Summary = {
  client_completed_services?: number
  client_loyalty_count?: number
  client_rewards_available?: number
  client_rewards_applied?: number
  client_loyalty_amount?: number
  provider_loyalty_count?: number
  provider_loyalty_amount?: number
  provider_limit?: number
  provider_remaining?: number
  provider_active?: boolean
  cancel_bonus_available?: number
  cancel_bonus_available_amount?: number
  cancel_bonus_used_amount?: number
  loyalty_rule?: string
}

type BenefitRow = {
  record_kind: string
  id: string
  person_id: string
  person_name?: string | null
  person_email?: string | null
  person_role?: string | null
  benefit_type?: string | null
  benefit_label?: string | null
  amount?: number | null
  status?: string | null
  source_booking_id?: string | null
  used_booking_id?: string | null
  issued_at?: string | null
  used_at?: string | null
}

const statusOptions = [
  ['all', 'Todos'],
  ['earned', 'Beneficio disponible'],
  ['applied', 'Beneficio aplicado'],
  ['paid', 'Bono pagado'],
  ['available', 'USD 7 disponible'],
  ['used', 'USD 7 usado'],
  ['cancelled', 'Cancelados'],
] as const

export default function BenefitsPage() {
  const [summary, setSummary] = useState<Summary>({})
  const [rows, setRows] = useState<BenefitRow[]>([])
  const [search, setSearch] = useState('')
  const [appliedSearch, setAppliedSearch] = useState('')
  const [status, setStatus] = useState('all')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    const [s, r] = await Promise.all([
      supabase.rpc('wissa_loyalty_admin_summary_v60'),
      supabase.rpc('wissa_loyalty_admin_rows_v60', { p_search: appliedSearch, p_status: status, p_limit: 250 }),
    ])
    if (s.error) setError(s.error.message)
    if (r.error) setError((current) => current || r.error.message)
    setSummary((s.data || {}) as Summary)
    setRows(Array.isArray(r.data) ? (r.data as BenefitRow[]) : [])
    setLoading(false)
  }, [appliedSearch, status])

  useEffect(() => { void load() }, [load])

  const providerLimit = Number(summary.provider_limit ?? 10)
  const providerUsed = Number(summary.provider_loyalty_count ?? 0)
  const providerRemaining = Number(summary.provider_remaining ?? Math.max(providerLimit - providerUsed, 0))
  const loyaltyIssued = Number(summary.client_loyalty_count ?? 0)
  const loyaltyAvailable = Number(summary.client_rewards_available ?? 0)
  const loyaltyApplied = Number(summary.client_rewards_applied ?? 0)
  const loyaltyAmount = Number(summary.client_loyalty_amount ?? 0)

  return <div className="admin-page">
    <section className="hero">
      <div className="hero-row">
        <div>
          <div className="eyebrow">FIDELIDAD Y BONOS</div>
          <h1>Beneficios Wissa</h1>
          <p className="subtitle">
            La promoción de “primeros 10 clientes” ya no aplica. Cada cliente desbloquea 50% sobre el valor de su siguiente servicio elegible por cada 10 servicios completados. El ciclo vuelve a comenzar después de usar el beneficio. Se mantienen el bono de lanzamiento de USD 50 para Ofrecer elegibles y la compensación de USD 7 por cancelación tardía.
          </p>
        </div>
        <div className="hero-actions">
          <span className="badge green">Fidelidad recurrente activa</span>
          <button className="btn btn-primary" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={16}/>{loading ? 'Actualizando...' : 'Actualizar'}
          </button>
        </div>
      </div>
    </section>

    {error ? <div className="error" style={{ marginBottom: 18 }}>{adminMessage(error)}</div> : null}

    <section className="stats">
      <BenefitStat icon={<Percent size={18}/>} label="Beneficios fidelidad generados" value={String(loyaltyIssued)} helper={`${loyaltyAvailable} disponibles · ${loyaltyApplied} ya aplicados`}/>
      <BenefitStat icon={<BadgeDollarSign size={18}/>} label="Descuento fidelidad aplicado" value={money(loyaltyAmount)} helper="Lo cubre Wissa, sin reducir el pago al profesional"/>
      <BenefitStat icon={<Users size={18}/>} label={`Bono Ofrecer · ${providerUsed}/${providerLimit}`} value={String(providerRemaining)} helper={`${money(Number(summary.provider_loyalty_amount ?? 0))} acumulados · bonos restantes`}/>
      <BenefitStat icon={<TicketCheck size={18}/>} label="Bono cancelación · USD 7" value={String(summary.cancel_bonus_available ?? 0)} helper={`${money(Number(summary.cancel_bonus_available_amount ?? 0))} disponibles`}/>
      <BenefitStat icon={<Gift size={18}/>} label="Servicios completados" value={String(summary.client_completed_services ?? 0)} helper="Base acumulada para ciclos de fidelidad de clientes"/>
    </section>

    <section className="card" style={{ marginTop: 18, marginBottom: 18 }}>
      <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center' }}>
        <div style={{ position: 'relative', flex: '1 1 300px' }}>
          <Search size={16} style={{ position: 'absolute', left: 13, top: 13, opacity: .55 }}/>
          <input className="input" style={{ width: '100%', paddingLeft: 38 }} value={search} onChange={(e) => setSearch(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') setAppliedSearch(search.trim()) }} placeholder="Buscar cliente, ofrecer, correo o beneficio..."/>
        </div>
        <select className="input" value={status} onChange={(e) => setStatus(e.target.value)}>
          {statusOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
        <button className="btn btn-soft" onClick={() => setAppliedSearch(search.trim())}>Buscar</button>
        <button className="btn btn-soft" onClick={() => { setSearch(''); setAppliedSearch(''); setStatus('all') }}>Limpiar</button>
      </div>
    </section>

    <section className="card table-card">
      <div className="table-wrap">
        <table className="table responsive-table">
          <thead><tr><th>Persona</th><th>Beneficio</th><th>Monto</th><th>Estado</th><th>Reserva origen</th><th>Emitido</th></tr></thead>
          <tbody>
            {rows.map((row) => <tr key={`${row.record_kind}:${row.id}`}>
              <td data-label="Persona"><strong>{row.person_name || 'Usuario'}</strong><div className="secondary">{row.person_role || 'Usuario'} · {row.person_email || 'Sin correo'}</div></td>
              <td data-label="Beneficio"><strong>{row.benefit_label || row.benefit_type || 'Beneficio Wissa'}</strong></td>
              <td data-label="Monto">{money(Number(row.amount || 0))}</td>
              <td data-label="Estado"><BenefitStatus value={row.status || ''}/></td>
              <td data-label="Reserva origen">{shortId(row.source_booking_id)}</td>
              <td data-label="Emitido">{row.issued_at ? formatPanamaDateTime(row.issued_at) : '—'}</td>
            </tr>)}
            {!loading && !rows.length ? <tr><td colSpan={6}><div className="empty">No hay beneficios que coincidan con los filtros.</div></td></tr> : null}
            {loading && !rows.length ? <tr><td colSpan={6}><div className="empty">Cargando beneficios...</div></td></tr> : null}
          </tbody>
        </table>
      </div>
    </section>
  </div>
}

function BenefitStat({ icon, label, value, helper }: { icon: React.ReactNode; label: string; value: string; helper: string }) {
  return <div className="stat"><div style={{ display: 'flex', alignItems: 'center', gap: 8 }}><span>{icon}</span><span>{label}</span></div><strong>{value}</strong><small>{helper}</small></div>
}

function BenefitStatus({ value }: { value: string }) {
  const normalized = value.toLowerCase()
  const cls = ['available', 'earned', 'paid'].includes(normalized) ? 'green' : normalized === 'applied' || normalized === 'used' ? 'cyan' : 'red'
  const label = normalized === 'available' ? 'Disponible' : normalized === 'earned' ? 'Disponible' : normalized === 'applied' ? 'Aplicado' : normalized === 'paid' ? 'Pagado' : normalized === 'used' ? 'Usado' : normalized === 'cancelled' ? 'Cancelado' : value
  return <span className={`badge ${cls}`}>{label}</span>
}

function shortId(value?: string | null) { return value ? `${value.slice(0, 8)}…` : '—' }
