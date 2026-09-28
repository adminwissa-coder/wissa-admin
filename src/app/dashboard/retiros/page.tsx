import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Retiros de profesionales"
      eyebrow="LIQUIDACIONES"
      description="Gestiona solicitudes, pagos pendientes y comprobantes por profesional, categoría y pasarela."
      rpc="yt_admin_withdrawals_v66_json"
      actions="withdrawals"
      enableDateFilter
      searchPlaceholder="Profesional, reserva, categoría, pasarela, Yappy, banco o referencia"
      statusOptions={["all", "provider_pending", "pending", "paid", "cancelled", "provider_payout", "payout_request"]}
      facetFilters={[
        {key:'service_category',label:'Categoría',allLabel:'Todas las categorías'},
        {key:'gateway',label:'Pasarela',allLabel:'Todas las pasarelas'},
      ]}
      columns={[
        { key: "source", label: "Tipo", type: "status" },
        { key: "reservation_code", label: "Reserva" },
        { key: "service_title", label: "Servicio" },
        { key: "service_category", label: "Categoría" },
        { key: "provider_name", label: "Profesional" },
        { key: "status", label: "Estado", type: "status" },
        { key: "amount", label: "Total a liquidar", type: "money" },
        { key: "service_amount", label: "Servicio", type: "money" },
        { key: "extras_amount", label: "Extras incluidos", type: "money" },
        { key: "travel_fee", label: "Traslado", type: "money" },
        { key: "tip_amount", label: "Propina", type: "money" },
        { key: "gateway", label: "Pasarela cliente" },
        { key: "payout_method", label: "Cobro profesional" },
        { key: "payout_destination", label: "Destino" },
        { key: "method", label: "Registro" },
        { key: "reference", label: "Referencia" },
        { key: "created_at", label: "Creado", type: "datetime" },
      ]}
    />
  );
}
