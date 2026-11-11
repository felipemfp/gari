import { test } from "node:test";
import assert from "node:assert/strict";
import { collect, recommend, type Stat } from "./report.ts";

// Fixtures follow the real report from the machine this feature was built for.
const GB = 1e9;
const s = (section: string, label: string, bytes: number, data?: Record<string, unknown>): Stat => ({
  section,
  label,
  bytes,
  data,
});

const field: Stat[] = [
  s("win-drive", "C:", 465 * GB, { size: 475 * GB, free: 9.1 * GB }),
  s("vhdx", "Ubuntu", 160.7 * GB, { path: "C:\\u\\ext4.vhdx", size: 169.1 * GB, used: 146 * GB, sparse: true }),
  s("vhdx", "docker", 73 * GB, { path: "C:\\d\\docker_data.vhdx", size: 73 * GB, used: 34 * GB, sparse: false }),
  s("poetry", "virtualenvs", 20 * GB, { count: 69, orphaned: 42, orphaned_bytes: 11 * GB }),
  s("clean-caches", "caches", 12.8 * GB, { count: 10 }),
  s("clean-worktrees", "worktrees", 0.1 * GB, { count: 1 }),
  s("clean-stale-deps", "stale-deps", 0, { count: 0 }),
  s("wsl-worktrees", "/h/.claude-worktrees/ui-1", 21.5 * GB),
  s("wsl-worktrees", "/h/.claude-worktrees/gari-2", 9.5 * GB),
  s("docker", "Images", 1.1 * GB, { reclaimable: 0.2 * GB }),
  s("docker", "Build Cache", 3 * GB, { reclaimable: 3 * GB }),
  s("docker-volumes", "anonymous", 33.7 * GB, { count: 326 }),
  s("docker-volumes", "named", 1.4 * GB, { count: 1, names: ["ui-dev-kit_npm-node_modules"] }),
  s("wsl-big", "/home/x/.flair/model.bin", 2.2 * GB, { age_days: 943 }),
  s("wsl-big", "/home/x/.cache/trivy/db/trivy.db", 1.7 * GB, { age_days: 8 }),
  s("win-big", "C:\\Users\\x\\AppData\\Local\\Marvel\\Saved\\Crashes\\a\\UEMinidump.full.dmp", 0.78 * GB, { age_days: 700 }),
  s("win-big", "C:\\Users\\x\\Videos\\wedding.mov", 3.1 * GB, { age_days: 40 }),
  s("win-system", "C:\\WINDOWS\\SoftwareDistribution\\Download", 1.6 * GB),
  s("win-system", "C:\\Users\\x\\AppData\\Local\\Temp", 0.8 * GB),
  s("win-programs", "Microsoft Windows Desktop Runtime - 6.0.32 (x64)", 0.21 * GB, { installed: "", version: "6.0.32" }),
  s("win-programs", "Microsoft Windows Desktop Runtime - 6.0.29 (x64)", 0.2 * GB, { installed: "", version: "6.0.29" }),
  s("win-programs", "Microsoft Windows Desktop Runtime - 8.0.26 (x64)", 0.21 * GB, { installed: "", version: "8.0.26" }),
  s("win-programs", "Docker Desktop", 3.3 * GB, { installed: "", version: "4.50" }),
];

const byId = (stats: Stat[]) => new Map(recommend(collect(stats)).map((r) => [r.id, r]));

test("collect groups by section in arrival order", () => {
  const r = collect(field);
  assert.equal(r.get("vhdx")?.length, 2);
  assert.equal(r.get("vhdx")?.[0].label, "Ubuntu");
  assert.equal(r.get("nope"), undefined);
});

test("C: at 98% raises a high-severity alert first", () => {
  const recs = recommend(collect(field));
  assert.equal(recs[0].id, "drive-full:C:");
  assert.equal(recs[0].severity, "high");
});

test("a sparse disk with slack gets a compaction rec that explains the trim", () => {
  const r = byId(field).get("vhdx:Ubuntu")!;
  assert.equal(r.category, "vhdx");
  assert.ok(Math.abs(r.bytes - 14.7 * GB) < 1e6);
  assert.match(r.detail, /auto-shrink/i);
});

test("docker disk slack and orphaned volumes each map to their category", () => {
  const m = byId(field);
  assert.equal(m.get("vhdx:docker")?.category, "vhdx");
  assert.equal(m.get("docker-volumes")?.category, "docker-volumes");
  assert.equal(m.get("docker-volumes")?.bytes, 33.7 * GB);
  assert.equal(m.get("docker")?.bytes, 3.2 * GB);
});

test("named dangling volumes are a manual review, never a category", () => {
  const r = byId(field).get("docker-named-volumes")!;
  assert.equal(r.category, undefined);
  assert.match(r.detail, /ui-dev-kit_npm-node_modules/);
});

test("orphaned poetry envs, caches map to categories; empty categories do not show", () => {
  const m = byId(field);
  assert.equal(m.get("poetry-envs")?.bytes, 11 * GB);
  assert.equal(m.get("caches")?.category, "caches");
  assert.equal(m.has("stale-deps"), false);
  assert.equal(m.has("worktrees"), false, "100 MB is below the bar");
});

test("big worktree folders gari cannot remove point to manual review", () => {
  const r = byId(field).get("worktrees-manual")!;
  assert.equal(r.category, undefined);
  assert.match(r.detail, /ui-1/);
});

test("old big files and crash dumps are listed; recent ones are not", () => {
  const m = byId(field);
  assert.match(m.get("old-wsl-files")!.detail, /~\/\.flair/, "home shortened to ~");
  assert.doesNotMatch(m.get("old-wsl-files")!.detail, /trivy/);
  assert.match(m.get("crash-dumps")!.detail, /Marvel \(1 file\)/, "dumps grouped by app");
  assert.equal(m.has("old-win-files"), false, "the 40-day-old video is not old");
});

test("out-of-support .NET runtimes are found by major version", () => {
  const r = byId(field).get("dotnet")!;
  assert.match(r.detail, /6\.0\.32/);
  assert.doesNotMatch(r.detail, /8\.0/);
  assert.ok(Math.abs(r.bytes - 0.41 * GB) < 1e6);
});

test("windows update cache over 1 GB suggests Disk Cleanup; temp under 1 GB does not", () => {
  const m = byId(field);
  assert.match(m.get("win-system:C:\\WINDOWS\\SoftwareDistribution\\Download")!.detail, /Disk Cleanup/);
  assert.equal(m.has("win-system:C:\\Users\\x\\AppData\\Local\\Temp"), false);
});

test("auto-shrink off on the distro disk is suggested; on, it is not", () => {
  const off = field.map((x) => (x.section === "vhdx" && x.label === "Ubuntu" ? { ...x, data: { ...x.data, sparse: false } } : x));
  assert.equal(byId(off).get("sparse")?.action, "sparse");
  assert.equal(byId(field).has("sparse"), false);
});

test("recommendations after the alert are ordered by bytes, largest first", () => {
  const rest = recommend(collect(field)).filter((r) => r.severity !== "high");
  for (let i = 1; i < rest.length; i++) assert.ok(rest[i - 1].bytes >= rest[i].bytes, `${rest[i - 1].id} < ${rest[i].id}`);
});

test("a healthy, empty report has no recommendations", () => {
  assert.deepEqual(recommend(collect([s("win-drive", "C:", 100 * GB, { size: 500 * GB, free: 400 * GB })])), []);
});

test("missing counts never print 'undefined'", () => {
  const r = byId([s("poetry", "virtualenvs", 20 * GB, { orphaned_bytes: 11 * GB })]).get("poetry-envs")!;
  assert.doesNotMatch(r.detail, /undefined/);
});

test("unknown usage inside a disk gives no made-up slack", () => {
  const m = byId([s("vhdx", "docker", 73 * GB, { path: "p", size: 73 * GB, used: null, sparse: false })]);
  assert.equal(m.has("vhdx:docker"), false);
});
