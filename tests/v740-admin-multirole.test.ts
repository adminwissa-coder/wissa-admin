import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (p: string) => fs.readFileSync(path.join(root, p), 'utf8');

test('V74 Admin cuenta profesionales con la misma regla del listado Ofrecer', () => {
  const page = read('src/app/dashboard/page.tsx');
  assert.match(page, /yt_admin_provider_count_v74/);
  assert.doesNotMatch(page, /role\.eq\.provider,account_type\.eq\.provider,mode_preference\.eq\.provider/);
});

test('V74 Admin muestra capacidad Cliente + Ofrecer sin duplicar identidad', () => {
  const users = read('src/app/dashboard/usuarios/page.tsx');
  const utils = read('src/lib/utils.ts');
  assert.match(users, /key: "role", label: "Cuenta"/);
  assert.match(utils, /both: "Cliente \+ Ofrecer"/);
});

test('V74 SQL de Admin mantiene usuarios ambos visibles como clientes y profesionales', () => {
  const sql = read('supabase/sql/WISSA-V74.0.2-ADMIN-MULTIROLE-APPLY.sql');
  assert.match(sql, /yt_admin_clients_json/);
  assert.match(sql, /both/);
  assert.match(sql, /yt_admin_provider_count_v74/);
  assert.doesNotMatch(sql, /delete\s+from\s+auth\.users/i);
});
