import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Servicios"
      eyebrow="Catálogo"
      description="Consulta los servicios, sus tarifas y las reservas recibidas."
      rpc="yt_admin_services_json"
      enableDateFilter
      statusOptions={["all", "active", "inactive"]}
      facetFilters={[{ key: "category", label: "Categoría", allLabel: "Todas las categorías" }]}
      excludedFacetValues={{ category: ["Plomería", "Plomeria", "Plumbing"] }}
      searchPlaceholder="Buscar por servicio, profesional o categoría..."
      columns={[
        { key: "service_title", label: "Servicio" },
        { key: "provider_name", label: "Profesional" },
        { key: "category", label: "Categoría" },
        { key: "status", label: "Estado", type: "status" },
        { key: "base_price", label: "Tarifa del servicio", type: "money" },
        { key: "bookings_count", label: "Reservas" },
        { key: "total_booked_amount", label: "Total reservado", type: "money" },
        { key: "created_at", label: "Creado", type: "datetime" },
      ]}
    />
  );
}
