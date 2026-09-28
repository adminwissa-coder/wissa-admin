import Link from "next/link";
import { Building2, CircleDollarSign, HandCoins, ReceiptText } from "lucide-react";

const options = [
  { title: "Profesionales", description: "Revisa solicitudes, pagos pendientes y comprobantes de cada profesional.", href: "/dashboard/retiros", icon: HandCoins },
  { title: "Empresas", description: "Controla las liquidaciones correspondientes a servicios empresariales.", href: "/dashboard/empresas-liquidaciones", icon: Building2 },
  { title: "Ingresos Wissa", description: "Consulta comisiones disponibles y retiros registrados de la plataforma.", href: "/dashboard/retiro-comision", icon: CircleDollarSign },
  { title: "Distribución", description: "Audita el reparto financiero de reservas con uno o varios profesionales.", href: "/dashboard/distribucion", icon: ReceiptText },
];

export default function LiquidacionesPage() {
  return (
    <div className="simple-module-page ui2-hub-page">
      <section className="simple-section-head">
        <div>
          <span>Pagos y liquidaciones</span>
          <h2>Todo lo que debes pagar, en un solo lugar</h2>
          <p>Separamos la operación diaria de los movimientos financieros para que sea más fácil revisar y actuar.</p>
        </div>
      </section>
      <section className="simple-hub-grid">
        {options.map(({ title, description, href, icon: Icon }) => (
          <Link href={href} className="simple-hub-card" key={href}>
            <div className="simple-hub-icon"><Icon size={22} /></div>
            <div><strong>{title}</strong><p>{description}</p></div>
            <span>Ver módulo →</span>
          </Link>
        ))}
      </section>
    </div>
  );
}
