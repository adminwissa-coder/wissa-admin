"use client";

import { adminMessage } from "@/lib/admin-copy";

import { useCallback, useEffect, useMemo, useState } from "react";
import { BadgeDollarSign, ExternalLink, RefreshCcw, Users } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useRealtimeRefresh } from "@/hooks/useRealtimeRefresh";
import { datetime, money, statusLabel } from "@/lib/utils";

type BookingRow = {
  id: string;
  reservation_code?: string | null;
  service_title?: string | null;
  created_at?: string | null;
  status?: string | null;
  payment_status?: string | null;
  total_amount?: number | null;
  provider_pool_amount?: number | null;
  commission_rate_snapshot?: number | null;
  required_professionals?: number | null;
  accepted_professionals?: number | null;
};

type TeamMember = {
  slot?: number;
  provider_id?: string;
  provider_name?: string;
  status?: string;
  gross_provider_amount?: number;
  commission_amount?: number;
  service_share?: number;
  extras_share?: number;
  travel_distance_km?: number;
  travel_rate_per_km?: number;
  travel_fee?: number;
  net_provider_amount?: number;
  professional_payment?: number;
  payout_status?: string;
  payout_id?: string | null;
  tip_amount?: number;
  receipt_bucket?: string | null;
  receipt_path?: string | null;
};

type Distribution = {
  booking_id?: string;
  reservation_code?: string;
  status?: string;
  payment_status?: string;
  payout_release_status?: string;
  required_professionals?: number;
  accepted_professionals?: number;
  client_total?: number;
  gross_total?: number;
  service_subtotal?: number;
  wissa_commission?: number;
  platform_usage_fee?: number;
  kits_materials?: number;
  travel_total?: number;
  itbms?: number;
  loyalty_subsidy?: number;
  provider_pool?: number;
  commission_rate?: number;
  team?: TeamMember[];
};

export default function FinancialDistributionPage() {
  const [bookings, setBookings] = useState<BookingRow[]>([]);
  const [selectedId, setSelectedId] = useState("");
  const [distribution, setDistribution] = useState<Distribution | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadBookings = useCallback(async (silent = false) => {
    if (!silent) setLoading(true); setError("");
    const { data, error: loadError } = await supabase
      .from("bookings")
      .select("id,reservation_code,service_title,created_at,status,payment_status,total_amount,provider_pool_amount,commission_rate_snapshot,required_professionals,accepted_professionals")
      .order("created_at", { ascending: false }).limit(150);
    if (loadError) { setError(loadError.message); setLoading(false); return; }
    const rows=(data || []) as BookingRow[]; setBookings(rows);
    setSelectedId((current)=>current || rows[0]?.id || "");
    setLoading(false);
  },[]);

  const loadDistribution = useCallback(async (bookingId:string) => {
    if(!bookingId){setDistribution(null);return;}
    setError("");
    let result = await supabase.rpc("yt_admin_booking_distribution_v66",{p_booking_id:bookingId});
    if(result.error && /could not find the function|schema cache|does not exist|PGRST202/i.test(result.error.message)){
      result = await supabase.rpc("yt_admin_booking_distribution_v65",{p_booking_id:bookingId});
    }
    if(result.error){setError(result.error.message);setDistribution(null);return;}
    setDistribution((result.data || null) as Distribution | null);
  },[]);

  useEffect(()=>{void loadBookings();},[loadBookings]);
  useEffect(()=>{if(selectedId) void loadDistribution(selectedId);},[selectedId,loadDistribution]);

  const refreshDistribution = useCallback(async () => {
    await loadBookings(true);
    if (selectedId) await loadDistribution(selectedId);
  }, [loadBookings, loadDistribution, selectedId]);

  useRealtimeRefresh({
    scope: "admin-distribution",
    sources: [
      { table: "bookings" },
      { table: "booking_professional_assignments" },
      { table: "provider_payouts" },
      { table: "booking_tips" },
      { table: "booking_tip_allocations" },
      { table: "payment_orders" },
    ],
    onRefresh: refreshDistribution,
  });

  async function openReceipt(item: TeamMember){
    const path=String(item.receipt_path||"").trim();
    if(!path) return;
    const bucket=String(item.receipt_bucket||"provider-payout-receipts").trim();
    const {data,error}=await supabase.storage.from(bucket).createSignedUrl(path,300);
    if(error||!data?.signedUrl){setError(error?.message||"No se pudo abrir el comprobante.");return;}
    const target=window.open(data.signedUrl,"_blank","noopener,noreferrer");
    if(target) target.opener=null;
  }

  const selected=useMemo(()=>bookings.find((item)=>item.id===selectedId)||null,[bookings,selectedId]);
  const team=Array.isArray(distribution?.team)?distribution!.team!:[];
  const confirmedTeam=team.filter((item)=>item.status==='accepted'||item.status==='completed');
  const invitedCandidates=team.filter((item)=>item.status==='pending');
  const required=Math.max(1,Number(distribution?.required_professionals||1));
  const accepted=confirmedTeam.length;
  const teamTotal=confirmedTeam.reduce((sum,item)=>sum+Number(item.professional_payment ?? (Number(item.net_provider_amount||0)+Number(item.tip_amount||0))),0);

  return <div>
    <section className="hero"><div className="hero-row"><div><div className="eyebrow">Control financiero</div><h1>Distribución financiera</h1><p className="subtitle">Una reserva, un pago del cliente y una liquidación independiente por cada profesional. Revisa el reparto antes de liberar fondos.</p></div><button className="btn btn-primary" onClick={()=>void loadBookings()}><RefreshCcw size={17}/>Actualizar</button></div></section>
    {error?<div className="error" style={{marginBottom:16}}>{adminMessage(error)}</div>:null}
    <section className="card" style={{padding:22,marginBottom:18}}>
      <label><span className="label">Reserva</span><select className="select" value={selectedId} onChange={(e)=>setSelectedId(e.target.value)}>{bookings.map((booking)=><option key={booking.id} value={booking.id}>{booking.reservation_code || "Reserva sin código"} · {booking.service_title || "Servicio"} · {money(Number(booking.total_amount||0))}</option>)}</select></label>
      {selected?<p className="secondary" style={{marginTop:9}}>Creada {datetime(selected.created_at)} · {statusLabel(selected.status)} · {statusLabel(selected.payment_status)}</p>:null}
    </section>
    {loading?<div className="card empty">Cargando reservas...</div>:distribution?<>
      <section className="stats" style={{gridTemplateColumns:"repeat(auto-fit,minmax(180px,1fr))"}}>
        <Stat label="Total cliente" value={money(Number(distribution.client_total||0))}/>
        <Stat label="Servicio" value={money(Number(distribution.service_subtotal||0))}/>
        <Stat label={`Comisión Wissa ${Math.round(Number(distribution.commission_rate||0)*100)}%`} value={money(Number(distribution.wissa_commission||0))}/>
        <Stat label="Uso plataforma" value={money(Number(distribution.platform_usage_fee||0))}/>
        <Stat label="Kits/materiales" value={money(Number(distribution.kits_materials||0))}/>
        <Stat label="Traslado" value={money(Number(distribution.travel_total||0))}/>
        <Stat label="ITBMS" value={money(Number(distribution.itbms||0))}/>
        <Stat label="Beneficio financiado Wissa" value={money(Number(distribution.loyalty_subsidy||0))}/>
        <Stat label="Pago total a profesionales" value={money(Number(distribution.provider_pool ?? teamTotal))}/>
      </section>
      <section className="card table-card">
        <div style={{padding:22,display:"flex",gap:12,alignItems:"center"}}><div className="module-icon" style={{margin:0}}><Users size={21}/></div><div><h2 style={{margin:0}}>Equipo confirmado · {accepted} de {required}</h2><p className="subtitle">Cada profesional conserva su liquidación individual.</p></div></div>
        <div className="table-wrap"><table className="table"><thead><tr><th>Posición</th><th>Profesional</th><th>Estado</th><th>Servicio</th><th>Extras</th><th>Traslado</th><th>Propina</th><th>Pago profesional</th><th>Liquidación</th><th>Comprobante</th></tr></thead><tbody>{confirmedTeam.length?confirmedTeam.map((item)=><tr key={`${item.slot}-${item.provider_id}`}><td>#{item.slot}</td><td><div className="primary">{item.provider_name || "Profesional"}</div></td><td><span className={`badge ${item.status==="accepted"||item.status==="completed"?"green":"yellow"}`}>{statusLabel(item.status)}</span></td><td>{money(Number(item.service_share||0))}</td><td>{money(Number(item.extras_share||0))}</td><td>{money(Number(item.travel_fee||0))}</td><td>{money(Number(item.tip_amount||0))}</td><td><strong>{money(Number(item.professional_payment ?? (Number(item.net_provider_amount||0)+Number(item.tip_amount||0))))}</strong></td><td><span className={`badge ${item.payout_status==="paid"?"green":"yellow"}`}>{statusLabel(item.payout_status)}</span></td><td>{item.receipt_path?<button className="btn btn-soft btn-small" onClick={()=>void openReceipt(item)}><ExternalLink size={14}/>Ver</button>:<span className="secondary">—</span>}</td></tr>):<tr><td colSpan={10} className="empty">Esta reserva todavía no tiene profesionales finales confirmados.</td></tr>}</tbody></table></div>
      </section>
      {invitedCandidates.length?<section className="card" style={{padding:20,marginTop:18}}><div className="eyebrow">CANDIDATOS INVITADOS</div><h3 style={{margin:"6px 0 8px"}}>{invitedCandidates.length} solicitud{invitedCandidates.length===1?"":"es"} esperando respuesta</h3><p className="subtitle" style={{margin:0}}>El pago se distribuye entre los profesionales confirmados.</p></section>:null}
      <div className="notice" style={{marginTop:18}}><BadgeDollarSign size={16} style={{verticalAlign:"middle",marginRight:7}}/><strong>Control contable:</strong> el cliente paga una sola vez; kits, plataforma e ITBMS se mantienen separados del pago profesional. Cada profesional conserva su propio desglose de servicio, extras, traslado y propina.</div>
    </>:<div className="card empty">Selecciona una reserva.</div>}
  </div>;
}

function Stat({label,value}:{label:string;value:string}){return <div className="stat"><span>{label}</span><strong style={{fontSize:24}}>{value}</strong></div>}
