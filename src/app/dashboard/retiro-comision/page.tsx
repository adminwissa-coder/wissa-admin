import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Ingresos y retiros Wissa"
      eyebrow="COMISIONES"
      description="Controla comisión, kits y retiros de Wissa con filtros por categoría y pasarela."
      rpc="yt_admin_wissa_marketplace_revenue_v66_json"
      actions="platform_commissions"
      enableDateFilter
      searchPlaceholder="Servicio, categoría, cliente, profesional, pasarela o referencia"
      statusOptions={["all", "pending", "collected", "earned", "platform_commission_pending", "platform_commission_withdrawal", "platform_commission_earned"]}
      facetFilters={[
        {key:'service_category',label:'Categoría',allLabel:'Todas las categorías'},
        {key:'gateway',label:'Pasarela',allLabel:'Todas las pasarelas'},
      ]}
      columns={[
        { key: "source", label: "Tipo", type: "status" },
        { key: "service_title", label: "Concepto" },
        { key: "service_category", label: "Categoría" },
        { key: "buyer_name", label: "Cliente / cuenta" },
        { key: "provider_name", label: "Profesionales / admin" },
        { key: "gateway", label: "Pasarela" },
        { key: "commission_amount", label: "Comisión Wissa", type: "money" },
        { key: "kit_amount", label: "Kits/materiales", type: "money" },
        { key: "extras_amount", label: "Extras asociados", type: "money" },
        { key: "amount", label: "Total Wissa", type: "money" },
        { key: "status", label: "Estado", type: "status" },
        { key: "method", label: "Método" },
        { key: "reference", label: "Referencia" },
        { key: "created_at", label: "Fecha", type: "datetime" },
      ]}
    />
  );
}
