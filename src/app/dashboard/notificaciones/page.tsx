import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Notificaciones"
      eyebrow="Centro de avisos"
      description="Avisos enviados a clientes, profesionales y empresas, con su estado de entrega y lectura."
      rpc="yt_admin_notifications_json"
      actions="notifications"
      enableDateFilter
      searchPlaceholder="Buscar por titulo, mensaje, usuario, reserva, tipo o estado"
      statusOptions={["all", "unread", "read", "archived", "deleted", "pending", "queued", "sent", "failed", "skipped"]}
      facetFilters={[{ key: "type", label: "Tipo", allLabel: "Todos los tipos de aviso" }, { key: "source", label: "Canal", allLabel: "Todos los canales" }]}
      columns={[
        { key: "title", label: "Titulo" },
        { key: "message", label: "Mensaje" },
        { key: "type", label: "Tipo" },
        { key: "source", label: "Origen", type: "status" },
        { key: "push_status", label: "Entrega", type: "status" },
        { key: "read_status", label: "Lectura", type: "status" },
        { key: "created_at", label: "Fecha y hora", type: "datetime" },
      ]}
    />
  );
}
