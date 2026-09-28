import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const failures = [];
const exists = (p) => fs.existsSync(path.join(root, p));
const artifactMode = process.argv.includes('--artifact') || process.env.WISSA_ARTIFACT_AUDIT === '1';

if (artifactMode) {
  for (const secret of ['.env', '.env.local', '.env.production']) {
    if (exists(secret)) failures.push(`No debe incluirse ${secret} en el ZIP de entrega.`);
  }
}
if (exists('tsconfig.tsbuildinfo')) failures.push('tsconfig.tsbuildinfo es un artefacto generado y no debe distribuirse.');

const src = path.join(root, 'src');
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.isFile() && (entry.name.endsWith('.tsx') || entry.name.endsWith('.ts'))) {
      const peer = entry.name.endsWith('.tsx') ? entry.name.slice(0, -4) + '.jsx' : entry.name.slice(0, -3) + '.js';
      if (fs.existsSync(path.join(dir, peer))) failures.push(`Fuente duplicada TS/JS: ${path.relative(root, full)} + ${peer}`);
    }
  }
}
if (fs.existsSync(src)) walk(src);

for (const required of [
  'src/components/admin/AdminShell.tsx',
  'src/app/dashboard/page.tsx',
  'src/app/dashboard/finanzas/page.tsx',
]) {
  if (!exists(required)) failures.push(`Falta artefacto UI2 requerido: ${required}`);
}

if (failures.length) {
  console.error('UI2 release audit FAILED');
  failures.forEach((item) => console.error(`- ${item}`));
  process.exit(1);
}
console.log(`UI2 release audit OK — Admin limpio. ${artifactMode ? 'Artefacto sin secretos.' : '.env local permitido; validar artefacto con --artifact.'}`);
