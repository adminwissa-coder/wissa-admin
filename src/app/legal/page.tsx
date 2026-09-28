import Link from "next/link";
import { ArrowRight, FileText, LifeBuoy, ShieldCheck, Trash2 } from "lucide-react";

const legalItems = [
  {
    href: "/legal/privacy",
    icon: ShieldCheck,
    title: "Política de privacidad",
    body: "Cómo Wissa recopila, usa, protege y conserva la información de usuarios, proveedores y empresas.",
  },
  {
    href: "/legal/terms",
    icon: FileText,
    title: "Términos y condiciones",
    body: "Reglas de uso, reservas, pagos manuales, liquidaciones, responsabilidades y soporte.",
  },
  {
    href: "/legal/delete-account",
    icon: Trash2,
    title: "Eliminar cuenta",
    body: "Ruta pública para solicitar eliminación de cuenta y datos visibles asociados.",
  },
  {
    href: "/legal/support",
    icon: LifeBuoy,
    title: "Soporte",
    body: "Canal público para consultas sobre cuentas, reservas, pagos, privacidad y seguridad.",
  },
];

export default function LegalHomePage() {
  return (
    <main className="legal-public-bg">
      <section className="legal-public-shell">
        <div className="legal-public-hero">
          <div>
            <p className="legal-public-eyebrow">Wissa Legal</p>
            <h1>Privacidad, términos, soporte y control de cuenta</h1>
            <p>
              Centro de información y cumplimiento para usuarios de Wissa,
              proveedores, empresas y personal de empresa.
            </p>
          </div>
        </div>

        <div className="legal-public-grid">
          {legalItems.map((item) => {
            const Icon = item.icon;
            return (
              <Link key={item.href} href={item.href} className="legal-public-card">
                <span className="legal-public-icon">
                  <Icon size={22} />
                </span>
                <strong>{item.title}</strong>
                <p>{item.body}</p>
                <span className="legal-public-link">
                  Abrir <ArrowRight size={16} />
                </span>
              </Link>
            );
          })}
        </div>
      </section>
    </main>
  );
}
