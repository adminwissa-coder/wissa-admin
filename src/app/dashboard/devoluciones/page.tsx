import AdminTablePage from "@/components/admin/AdminTablePage";

export default function RefundsPage() {
  return (
    <AdminTablePage
      title="Devoluciones"
      eyebrow="Reservas canceladas"
      description="Gestiona los reembolsos pendientes. Confirma cada devolución después de realizar la transferencia."
      rpc="yt_admin_refunds_json"
      actions="refunds"
      enableDateFilter
      searchPlaceholder="Buscar por cliente, profesional, servicio, referencia o motivo..."
      statusOptions={["all", "refund_pending", "refund_processing", "refunded", "refund_rejected"]}
      columns={[
        { key: "service_title", label: "Servicio" },
        { key: "buyer_name", label: "Cliente" },
        { key: "provider_name", label: "Profesional" },
        { key: "amount", label: "Monto", type: "money" },
        { key: "payment_method", label: "Método" },
        { key: "status", label: "Estado", type: "status" },
        { key: "paid_at", label: "Pago", type: "datetime" },
        { key: "requested_at", label: "Solicitada", type: "datetime" },
      ]}
    />
  );
}
