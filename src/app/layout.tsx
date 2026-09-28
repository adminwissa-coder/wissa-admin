import type { Metadata } from "next";
import "./globals.css";
import "./admin-overrides.css";
import "./wissa-ui2.css";
import "./wissa-premium-v70.css";

export const metadata: Metadata = {
  title: "Wissa Admin · Centro de gestión",
  description: "Centro de gestión de reservas, profesionales, empresas y finanzas de Wissa",
  icons: { icon: "/brand/wissa-favicon.png", apple: "/brand/wissa-icon.png" },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es" suppressHydrationWarning>
      <head>
        <script
          dangerouslySetInnerHTML={{
            __html: `(function(){try{var t=localStorage.getItem('yt-admin-theme');if(t!=='light'&&t!=='dark'){t=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'}document.documentElement.dataset.adminTheme=t;document.documentElement.style.colorScheme=t}catch(e){}})();`,
          }}
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
