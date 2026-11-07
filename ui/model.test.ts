import { test } from "node:test";
import assert from "node:assert/strict";
import { ago, apply, emptyState, human, progress, scannedPaths, total, type CategoryState } from "./model.ts";

test("apply collects items, totals, and errors per category", () => {
  const m = new Map<string, CategoryState>([["caches", emptyState()]]);
  apply(m, { event: "item", category: "caches", path: "/a", bytes: 10 });
  apply(m, { event: "item", category: "caches", path: "/b", bytes: 5 });
  apply(m, { event: "item", category: "other", path: "/x", bytes: 99 });
  apply(m, { event: "done", category: "caches", bytes: 15, count: 2 });
  const s = m.get("caches")!;
  assert.equal(total(s), 15);
  assert.equal(s.scanned, true);
  apply(m, { event: "done", category: "caches", bytes: 0, count: 0, error: "boom" });
  assert.equal(s.error, "boom");
});

test("a failed scan leaves nothing cleanable", () => {
  const m = new Map<string, CategoryState>([["docker", emptyState()]]);
  apply(m, { event: "item", category: "docker", path: "docker: Images", bytes: 10 });
  apply(m, { event: "done", category: "docker", bytes: 0, count: 0, error: "exited with 1" });
  const s = m.get("docker")!;
  assert.equal(s.scanned, false);
  assert.deepEqual(s.items, []);
  assert.deepEqual(scannedPaths(m, ["docker"]), {});
});

test("scannedPaths sends back exactly what each scanned category listed", () => {
  const m = new Map<string, CategoryState>([
    ["caches", emptyState()],
    ["stale-deps", emptyState()],
  ]);
  apply(m, { event: "item", category: "caches", path: "/a", bytes: 1 });
  apply(m, { event: "done", category: "caches", bytes: 1, count: 1 });
  apply(m, { event: "item", category: "stale-deps", path: "/n", bytes: 1 });
  assert.deepEqual(scannedPaths(m, ["caches", "stale-deps"]), { caches: ["/a"] });
});

test("progress moves within a step as items are removed", () => {
  const s = emptyState();
  s.items = [
    { path: "a", bytes: 1 },
    { path: "b", bytes: 1 },
  ];
  assert.equal(progress(0, 2, s), 0);
  s.removed = 1;
  assert.equal(progress(0, 2, s), 0.25);
  assert.equal(progress(1, 2, emptyState()), 0.5);
  s.removed = 5; // more removed than scanned (rescan drift) never exceeds the step
  assert.equal(progress(1, 2, s), 1);
  assert.equal(progress(0, 0), 0);
});

test("human matches the Rust formatter", () => {
  assert.equal(human(0), "0 B");
  assert.equal(human(999), "999 B");
  assert.equal(human(1_500_000_000), "1.5 GB");
});

test("ago", () => {
  assert.equal(ago(1000, 1000 * 1000 + 30_000), "just now");
  assert.equal(ago(0, 7200 * 1000), "2 h ago");
  assert.equal(ago(0, 3 * 86400 * 1000), "3 days ago");
});
