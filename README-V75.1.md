# Aplicar Wissa Admin V75.1

Copiar el patch sobre la raíz de Admin Web y ejecutar primero el SQL V75.1 en Supabase.

```powershell
npm run typecheck
npm test
npm run build
npx vercel@latest --prod
```

No requiere dependencias nuevas.
