import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dashboard = readFileSync(new URL("../src/app/dashboard/page.tsx", import.meta.url), "utf8");
const css = readFileSync(new URL("../src/app/wissa-ui2.css", import.meta.url), "utf8");

test("UI2-C dashboard keeps real Wissa data sources", () => {
  assert.match(dashboard, /yt_admin_dashboard_summary/);
  assert.match(dashboard, /yt_admin_bookings_v66_json/);
  assert.match(dashboard, /yt_admin_wissa_finance_v66_json/);
  assert.match(dashboard, /service_categories/);
});

test("UI2-C dashboard finance selector affects the real finance rows", () => {
  assert.match(dashboard, /selectedCategory/);
  assert.match(dashboard, /visibleFinance/);
  assert.match(dashboard, /aggregateFinance\(visibleFinance\)/);
  assert.match(dashboard, /Rendimiento por categoría/);
});

test("UI2-C keeps plumbing hidden non-destructively", () => {
  assert.match(dashboard, /isPlumbing/);
  assert.match(dashboard, /filter\(\(item\) => item\?\.name && !isPlumbing\(item\.name\)\)/);
  assert.doesNotMatch(dashboard, /delete\(\).*service_categories|from\("service_categories"\)\.delete/);
});

test("UI2-C includes responsive premium visual layer", () => {
  assert.match(css, /WISSA UI 2\.0 · UI2-C DASHBOARD/);
  assert.match(css, /\.ui2-kpi-grid/);
  assert.match(css, /\.ui2-category-switcher/);
  assert.match(css, /\.ui2-revenue-chart/);
  assert.match(css, /@media \(max-width: 520px\)/);
  assert.match(css, /prefers-reduced-motion/);
});
