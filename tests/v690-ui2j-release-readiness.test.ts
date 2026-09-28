import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const read = (p:string) => fs.readFileSync(path.join(root,p),'utf8');

test('UI2-J Admin permite entorno local pero conserva auditoría de artefacto sin secretos', () => {
  assert.equal(fs.existsSync(path.join(root,'tsconfig.tsbuildinfo')), false, 'tsconfig.tsbuildinfo');
  assert.equal(fs.existsSync(path.join(root,'.env.example')), true, '.env.example');
  const audit = read('scripts/ui2-release-audit.mjs');
  assert.match(audit, /artifactMode/);
  assert.match(audit, /--artifact/);
});

test('UI2-J Admin conserva shell, dashboard y finanzas UI2', () => {
  for (const p of ['src/components/admin/AdminShell.tsx','src/app/dashboard/page.tsx','src/app/dashboard/finanzas/page.tsx']) assert.equal(fs.existsSync(path.join(root,p)), true, p);
});

test('UI2-J Admin usa integración shadcn/Rare UI controlada', () => {
  assert.equal(fs.existsSync(path.join(root,'components.json')), true);
  const pkg = JSON.parse(read('package.json'));
  assert.equal(typeof pkg.dependencies?.shadcn, 'string');
});

test('UI2-J Admin incorpora auditoría reproducible de release', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.equal(pkg.scripts?.['ui2:audit'], 'node scripts/ui2-release-audit.mjs');
  assert.match(read('scripts/ui2-release-audit.mjs'), /UI2 release audit OK/);
});
