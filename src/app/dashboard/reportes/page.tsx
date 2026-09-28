import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Reportes"
      eyebrow="Métricas"
      description="Resumen general de operación, crecimiento, pagos, comisión plataforma 20% y liquidaciones."
      rpc="yt_admin_reports_json"
      enableDateFilter
      columns={[
        { key: "metric", label: "Métrica" },
        { key: "value", label: "Valor" },
        { key: "amount", label: "Monto", type: "money" },
        { key: "period_label", label: "Periodo" },
        { key: "created_at", label: "Fecha y hora", type: "datetime" },
      ]}
    />
  );
}
