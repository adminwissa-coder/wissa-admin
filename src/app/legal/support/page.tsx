import Link from "next/link";
import { ArrowLeft, LifeBuoy, Mail } from "lucide-react";

export default function SupportPage() {
  return (
    <main className="legal-public-bg">
      <article className="legal-public-document">
        <Link href="/legal" className="legal-back-link">
          <ArrowLeft size={16} /> Legal
        </Link>

        <div className="legal-public-title">
          <span className="legal-public-icon">
            <LifeBuoy size={24} />
          </span>
          <div>
            <p className="legal-public-eyebrow">Wissa</p>
            <h1>Soporte</h1>
            <p>Ayuda para cuentas, reservas, pagos, privacidad y seguridad.</p>
          </div>
        </div>

        <section>
          <h2>Cómo contactarnos</h2>
          <p>
            Describe el problema e incluye el correo de tu cuenta y, si aplica,
            el código visible de la reserva. Nunca envíes contraseñas, códigos de
            acceso ni datos completos de tarjetas.
          </p>
          <a className="legal-inline-action" href="mailto:soporte@wissa.app">
            <Mail size={16} /> soporte@wissa.app
          </a>
        </section>

        <section>
          <h2>Temas que atendemos</h2>
          <ul>
            <li>Acceso, recuperación y eliminación de cuenta.</li>
            <li>Reservas, pagos, devoluciones y liquidaciones.</li>
            <li>Verificación de proveedores y empresas.</li>
            <li>Privacidad, seguridad, reportes y contenido.</li>
          </ul>
        </section>

        <section>
          <h2>Tiempo de respuesta</h2>
          <p>
            Revisamos las solicitudes en días laborables. Los casos de pago,
            seguridad o eliminación pueden requerir validación adicional antes
            de completarse.
          </p>
        </section>
      </article>
    </main>
  );
}
