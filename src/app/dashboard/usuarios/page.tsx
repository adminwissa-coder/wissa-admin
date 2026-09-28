import AdminTablePage from "@/components/admin/AdminTablePage";

export default function Page() {
  return (
    <AdminTablePage
      title="Clientes"
      eyebrow="Usuarios que contratan"
      description="Consulta y administra las cuentas de clientes."
      rpc="yt_admin_clients_json"
      actions="users"
      enableDateFilter
      searchPlaceholder="Buscar cliente por nombre, correo, teléfono o ciudad..."
      statusOptions={["all", "active", "suspended"]}
      columns={[
        { key: "full_name", label: "Cliente", type: "user" },
        { key: "email", label: "Correo" },
        { key: "phone", label: "Teléfono" },
        { key: "city", label: "Ciudad" },
        { key: "role", label: "Cuenta", type: "status" },
        { key: "status", label: "Estado", type: "status" },
        { key: "created_at", label: "Creado", type: "date" },
      ]}
    />
  );
}
