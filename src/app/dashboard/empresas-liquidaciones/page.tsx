import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Liquidaciones empresas"
      eyebrow="Contabilidad empresas"
      description="Consulta y registra los pagos a empresas por sus servicios."
      rpc="yt_admin_company_services_finance_json"
      actions="company_liquidations"
      enableDateFilter
      searchPlaceholder="Buscar por empresa, servicio, personal, cliente o reserva..."
      statusOptions={["all", "pending", "paid", "completed", "released", "not_released", "failed", "cancelled"]}
      columns={[
        { key: "company_name", label: "Empresa" },
        { key: "service_title", label: "Servicio" },
        { key: "staff_name", label: "Personal" },
        { key: "buyer_name", label: "Cliente" },
        { key: "status_label", label: "Estado", type: "status" },
        { key: "payment_status", label: "Pago", type: "status" },
        { key: "release_status", label: "Liquidación", type: "status" },
        { key: "amount", label: "Total cobrado", type: "money" },
        { key: "platform_fee", label: "Comisión Wissa", type: "money" },
        { key: "company_net", label: "Monto a liquidar", type: "money" },
        { key: "created_at", label: "Creado", type: "datetime" },
      ]}
    />
  );
}
