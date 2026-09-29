WISSA ADMIN V75.4.1 — BADGE + TYPECHECK HOTFIX

Cambios incluidos:
1. Badge de notificaciones reposicionado dentro del botón:
   top: 4px / right: 4px.
2. Tests compatibles con target ES2017:
   se reemplazaron regex con flag /s por [\s\S]*.
3. Selector visual de Categorías y precios mantiene Plomería oculta,
   conservando su soporte interno.
4. .env.example restaurado solo con placeholders; no contiene secretos.
5. tsconfig.tsbuildinfo eliminado del artefacto.

Validaciones ejecutadas:
- npm test: 71/71 PASS
- npm run ui2:audit -- --artifact: PASS

No incluye .env.local, node_modules ni credenciales reales.
