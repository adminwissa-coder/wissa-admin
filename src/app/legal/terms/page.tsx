import Link from "next/link";
import { ArrowLeft, FileText, Mail } from "lucide-react";

export default function TermsPage() {
  return (
    <main className="legal-public-bg">
      <article className="legal-public-document">
        <Link href="/legal" className="legal-back-link">
          <ArrowLeft size={16} /> Legal
        </Link>

        <div className="legal-public-title">
          <span className="legal-public-icon">
            <FileText size={24} />
          </span>
          <div>
            <p className="legal-public-eyebrow">Wissa</p>
            <h1>Términos y condiciones</h1>
            <p>Vigentes desde el 17 de agosto de 2026</p>
          </div>
        </div>

        <section>
          <h2>1. Servicio</h2>
          <p>
            Wissa es una plataforma para conectar clientes, proveedores,
            empresas y personal de empresa. La app permite publicar servicios,
            buscar perfiles, crear reservas, pagar, dar seguimiento y registrar
            liquidaciones administrativas. Wissa facilita la relación y no
            sustituye las obligaciones profesionales de quien presta el
            servicio.
          </p>
        </section>

        <section>
          <h2>2. Cuentas y verificación</h2>
          <p>
            El usuario debe entregar información real y mantener acceso seguro a
            su cuenta. Los proveedores pueden requerir verificación documental.
            Wissa puede suspender cuentas ante riesgo, fraude, abuso o
            incumplimiento.
          </p>
        </section>

        <section>
          <h2>3. Reservas y pagos</h2>
          <p>
            Una reserva puede pasar por estados de pago, aceptación,
            completado y liberación. Los pagos de reservas de servicios físicos pueden procesarse por Yappy o PagueloFácil. La activación y renovación de planes empresariales se administra por los canales empresariales de Wissa y no se compra dentro de la aplicación móvil distribuida por las tiendas. El usuario debe revisar el monto,
            dirección, fecha, hora y detalle antes de confirmar.
          </p>
        </section>

        <section>
          <h2>4. Comisión de la plataforma</h2>
          <p>
            Para reservas pagadas, Wissa aplica una comisión de la plataforma de
            20%. El neto del proveedor se calcula sobre el monto aprobado menos
            la comisión. Las liquidaciones se registran desde el panel
            administrativo.
          </p>
        </section>

        <section>
          <h2>5. Empresas</h2>
          <p>
            Las empresas pueden requerir activación de plan, validación de pago,
            gestión de sedes, personal y reservas. El acceso empresarial puede
            bloquearse si el plan está vencido, pendiente de pago o suspendido.
          </p>
        </section>

        <section>
          <h2>6. Eliminación de cuenta</h2>
          <p>
            El usuario puede solicitar eliminación desde la app o desde la ruta
            pública. La solicitud crea trazabilidad administrativa y anonimiza u
            oculta datos visibles dentro de 30 días calendario, conservando solo
            datos estrictamente necesarios para soporte, contabilidad,
            seguridad, disputas o cumplimiento.
          </p>
        </section>

        <section>
          <h2>7. Conducta y contenido</h2>
          <p>
            No se permite fraude, suplantación, acoso, contenido ilegal,
            manipulación de pagos ni uso que afecte la seguridad de otros
            usuarios. Wissa puede filtrar contenido, recibir reportes de mensajes o reseñas, permitir bloqueos entre usuarios y limitar o suspender cuentas cuando sea necesario para proteger la plataforma. Los usuarios deben utilizar estas herramientas de buena fe.
          </p>
        </section>

        <section>
          <h2>8. Soporte y cambios</h2>
          <p>
            Podemos actualizar estos términos para reflejar cambios operativos o
            legales. La versión vigente y su fecha estarán disponibles en esta
            página. Para consultas:
          </p>
          <a className="legal-inline-action" href="mailto:soporte@wissa.app">
            <Mail size={16} /> soporte@wissa.app
          </a>
        </section>
      </article>
    </main>
  );
}
