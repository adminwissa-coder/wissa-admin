# Aplicar Admin V75.3

Copiar el patch sobre el Admin Web y ejecutar:

```powershell
npm run typecheck
node --experimental-strip-types --test tests\v753-banner-standards.test.ts
npm test
npm run build
```

Luego desplegar con `npx vercel@latest --prod`.
