import Link from "next/link";
import { ArrowLeft, Mail, ShieldCheck } from "lucide-react";

export default function PrivacyPage() {
  return (
    <main className="legal-public-bg">
      <article className="legal-public-document">
        <Link href="/legal" className="legal-back-link">
          <ArrowLeft size={16} /> Legal
        </Link>

        <div className="legal-public-title">
          <span className="legal-public-icon">
            <ShieldCheck size={24} />
          </span>
          <div>
            <p className="legal-public-eyebrow">Wissa</p>
            <h1>Política de privacidad</h1>
            <p>Vigente desde el 17 de agosto de 2026</p>
          </div>
        </div>

        <section>
          <h2>1. Alcance</h2>
          <p>
            Esta política describe cómo Wissa trata información cuando una
            persona usa la app móvil, el portal empresarial, las páginas
            públicas o los servicios administrativos relacionados.
          </p>
        </section>

        <section>
          <h2>2. Información que recopilamos</h2>
          <p>
            Recopilamos únicamente los datos necesarios para operar cuentas,
            verificar perfiles, publicar servicios, gestionar reservas,
            procesar pagos y brindar soporte.
          </p>
          <ul>
            <li>Cuenta y contacto: nombre, correo, teléfono, ciudad, rol, fotografía y preferencias.</li>
            <li>Ubicación: ubicación aproximada o precisa cuando el usuario la autoriza para calcular traslados o mostrar servicios.</li>
            <li>Proveedor y empresa: servicios, disponibilidad, sedes, personal, fotografías y documentos de verificación, incluido el récord policivo cuando corresponda.</li>
            <li>Reservas y contenido: servicio, fecha, hora, dirección, notas, chat, reseñas, reportes, bloqueos entre usuarios y confirmaciones.</li>
            <li>Pagos: método, pasarela, monto, estado, referencias, comisión de la plataforma y liquidación. Wissa no almacena los datos completos de una tarjeta.</li>
            <li>Datos de funcionamiento: identificadores, notificaciones y registros necesarios para mantener tu cuenta segura y brindar soporte.</li>
          </ul>
        </section>

        <section>
          <h2>3. Cómo usamos la información</h2>
          <p>
            Usamos la información para conectar clientes con proveedores,
            calcular precios y traslados, confirmar disponibilidad, procesar
            pagos, registrar liquidaciones, habilitar chat y notificaciones, moderar contenido, aplicar bloqueos de seguridad, prevenir fraude, resolver casos administrativos y cumplir obligaciones legales.
          </p>
        </section>

        <section>
          <h2>4. Proveedores tecnológicos</h2>
          <p>
            Para prestar el servicio podemos usar Supabase para autenticación,
            base de datos y almacenamiento; Expo para notificaciones; Google
            para inicio de sesión y mapas; y Yappy o PagueloFácil para pagos.
            Estos proveedores reciben solo la información necesaria para
            ejecutar su función y están sujetos a sus propios términos y
            políticas.
          </p>
        </section>

        <section>
          <h2>5. Pagos, comisión y liquidaciones</h2>
          <p>
            Wissa registra pagos de reservas de servicios físicos y, en sus canales empresariales, el estado de pagos de planes de empresa. La aplicación móvil de tienda no inicia cobros externos de membresía empresarial. La comisión de la plataforma es 20% sobre pagos aprobados de reservas. El neto
            del proveedor y los retiros se conservan para trazabilidad
            financiera, soporte y cumplimiento.
          </p>
        </section>

        <section>
          <h2>6. Retención y eliminación</h2>
          <p>
            Conservamos la información mientras la cuenta esté activa y durante
            el tiempo necesario para prestar el servicio. Puedes solicitar la
            eliminación desde la app o desde la ruta pública. La cuenta y los
            datos visibles se eliminarán o anonimizarán dentro de 30 días
            calendario, salvo información que deba conservarse por obligaciones
            contables, prevención de fraude, disputas, seguridad o cumplimiento
            legal. Cuando aplique una excepción, limitaremos el uso de esos
            registros al propósito que justificó su conservación.
          </p>
        </section>

        <section>
          <h2>7. Seguridad y transferencias</h2>
          <p>
            La información se almacena en Supabase con controles de acceso,
            políticas RLS y permisos por rol. Algunos proveedores pueden
            procesar datos fuera de Panamá. Aplicamos medidas razonables para
            proteger la información, aunque ningún sistema puede garantizar
            seguridad absoluta.
          </p>
        </section>

        <section>
          <h2>8. Menores y cambios</h2>
          <p>
            Wissa no está dirigida a menores de 18 años. Podemos actualizar esta
            política para reflejar cambios legales o funcionales y publicaremos
            la fecha de vigencia de la versión más reciente.
          </p>
        </section>

        <section>
          <h2>9. Tus opciones y contacto</h2>
          <p>
            Puedes actualizar información desde tu perfil, gestionar permisos
            desde el dispositivo y solicitar acceso, corrección o eliminación
            de datos. Para privacidad o soporte escribe a:
          </p>
          <a className="legal-inline-action" href="mailto:soporte@wissa.app">
            <Mail size={16} /> soporte@wissa.app
          </a>
        </section>
      </article>
    </main>
  );
}
