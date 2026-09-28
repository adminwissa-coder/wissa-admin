import Link from "next/link";
import { Bell, Gift, ImageIcon, Layers3, Settings2, SlidersHorizontal, UsersRound, Building2 } from "lucide-react";

const groups = [
  { title: "Categorías y precios", description: "Tarifas, comisiones y configuración comercial.", href: "/dashboard/categorias", icon: SlidersHorizontal },
  { title: "Extras y kits", description: "Gestiona complementos, materiales y kits disponibles.", href: "/dashboard/catalogo", icon: Layers3 },
  { title: "Planes empresariales", description: "Configura planes y condiciones para empresas.", href: "/dashboard/planes", icon: Building2 },
  { title: "Promociones y bonos", description: "Beneficios, fidelización y campañas activas.", href: "/dashboard/beneficios", icon: Gift },
  { title: "Banners", description: "Contenido visual mostrado dentro de la experiencia Wissa.", href: "/dashboard/banners", icon: ImageIcon },
  { title: "Clientes", description: "Consulta cuentas y estado de los usuarios clientes.", href: "/dashboard/usuarios", icon: UsersRound },
  { title: "Notificaciones", description: "Centro de avisos y seguimiento de entregas.", href: "/dashboard/notificaciones", icon: Bell },
  { title: "Reglas de equipo", description: "Configuración avanzada de cantidad de profesionales por servicio.", href: "/dashboard/equipos", icon: Settings2 },
];

export default function ConfiguracionPage() {
  return (
    <div className="simple-module-page ui2-hub-page">
      <section className="simple-section-head">
        <div>
          <span>Configuración</span>
          <h2>Ajustes del negocio</h2>
          <p>Los módulos de configuración están agrupados aquí para mantener el menú principal simple.</p>
        </div>
      </section>
      <section className="simple-hub-grid compact">
        {groups.map(({ title, description, href, icon: Icon }) => (
          <Link href={href} className="simple-hub-card" key={href}>
            <div className="simple-hub-icon"><Icon size={22} /></div>
            <div><strong>{title}</strong><p>{description}</p></div>
            <span>Abrir →</span>
          </Link>
        ))}
      </section>
      <div className="simple-info-note">
        <strong>Panel simplificado.</strong> Moderación y Casos dejan de mostrarse en la navegación principal para evitar duplicidad con Reportes y el flujo operativo actual. Sus rutas se conservan en el código por compatibilidad.
      </div>
    </div>
  );
}
