// Disk report: groups the backend's "stat" events and derives recommendations.
// Pure (no DOM) so the rules are unit tested with node:test. Every rule is a
// threshold over measured numbers; nothing here guesses.

import { human } from "./model.ts";

export interface Stat {
  section: string;
  label: string;
  bytes: number;
  data?: Record<string, unknown> | null;
}

export type Report = Map<string, Stat[]>;

export interface Rec {
  id: string;
  title: string;
  detail: string;
  /** Bytes it would free (0 when it is an alert, not a saving). */
  bytes: number;
  severity: "high" | "normal";
  /** A gari category that does this; the UI offers to tick it. */
  category?: string;
  /** A one-off action the UI can run instead. */
  action?: "sparse";
}

const GB = 1e9;
/** Below this a recommendation is noise. */
export const MIN_BYTES = 0.5 * GB;
/** A drive this full (or with less free than LOW_FREE) gets an alert. */
const FULL_RATIO = 0.9;
const LOW_FREE = 20 * GB;
/** Disk slack worth compacting (mirrors MinGap in scripts/vhdx.ps1). */
const MIN_GAP = 2 * 2 ** 30;
/** Files untouched this long are worth a look. */
const OLD_DAYS = 180;
/** .NET majors out of support (as of 2026-11: 8 and 9 end 2026-11-10, 10 is LTS). */
const DOTNET_EOL_BELOW = 8;

export function collect(stats: Iterable<Stat>): Report {
  const r: Report = new Map();
  for (const s of stats) {
    const list = r.get(s.section);
    if (list) list.push(s);
    else r.set(s.section, [s]);
  }
  return r;
}

const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const sum = (xs: Stat[]) => xs.reduce((a, x) => a + x.bytes, 0);
const short = (p: string) => p.replace(/^.*[\\/](?=[^\\/]+[\\/]?$)/, "").replace(/[\\/]$/, "");
/** Home folders shortened to ~ (full paths stay in the report tables). */
export const tilde = (p: string) => p.replace(/^[A-Za-z]:\\Users\\[^\\]+/, "~").replace(/^\/home\/[^/]+/, "~");
/** "Marvel" for ~\AppData\Local\Marvel\Saved\Crashes\...\x.dmp. */
const appOf = (p: string) => /\\AppData\\(?:Local|Roaming|LocalLow)\\([^\\]+)/i.exec(p)?.[1] ?? short(p.replace(/[\\/][^\\/]+$/, ""));
const listOf = (xs: string[], max = 5) =>
  xs.slice(0, max).join(", ") + (xs.length > max ? `, and ${xs.length - max} more` : "");

export const diskName = (label: string) => (label === "docker" ? "Docker" : label);

export function recommend(r: Report): Rec[] {
  const alerts: Rec[] = [];
  const recs: Rec[] = [];
  const get = (section: string) => r.get(section) ?? [];
  const one = (section: string, label: string) => get(section).find((s) => s.label === label);

  for (const d of get("win-drive")) {
    const size = num(d.data?.size);
    const free = num(d.data?.free);
    if (size === undefined || free === undefined || size <= 0) continue;
    if (free < LOW_FREE || d.bytes / size > FULL_RATIO) {
      alerts.push({
        id: `drive-full:${d.label}`,
        title: `${d.label} is ${Math.round((d.bytes / size) * 100)}% full`,
        detail: `${human(free)} free of ${human(size)}. Start with the largest items below.`,
        bytes: 0,
        severity: "high",
      });
    }
  }

  // Virtual disks: what the file takes on disk minus what is inside it.
  for (const v of get("vhdx")) {
    const used = num(v.data?.used);
    const sparse = v.data?.sparse === true;
    if (used !== undefined) {
      const gap = Math.max(0, v.bytes - used);
      if (gap >= MIN_GAP) {
        recs.push({
          id: `vhdx:${v.label}`,
          title: `Compact the ${diskName(v.label)} disk`,
          detail:
            `Its .vhdx takes ${human(v.bytes)} on disk for ${human(used)} of data. ` +
            (sparse
              ? "Auto-shrink is on but only returns space in 1 MB chunks, so the disk drifts up anyway. gari runs fstrim first (no admin) and fully compacts only if that is not enough."
              : "It never shrinks by itself. Clean the steps above first, then compact (shuts down WSL and Docker Desktop, asks for admin)."),
          bytes: gap,
          severity: "normal",
          category: "vhdx",
        });
      }
    }
    if (v.label !== "docker" && v.data?.sparse === false) {
      recs.push({
        id: "sparse",
        title: `Turn on auto-shrink for ${v.label}`,
        detail: "One-time switch: the distro disk then gives most freed space back to Windows by itself.",
        bytes: 0,
        severity: "normal",
        action: "sparse",
      });
    }
  }

  // The cleaner's own categories, measured with the same rules it cleans by.
  const cat = (section: string, category: string, title: string, detail: string) => {
    const s = get(section)[0];
    if (s && s.bytes >= MIN_BYTES) recs.push({ id: category, title, detail, bytes: s.bytes, severity: "normal", category });
  };
  cat("clean-caches", "caches", "Clear package and tool caches", "All re-downloadable: npm, yarn, bun, pip, poetry, browser binaries, old VS Code servers.");
  cat("clean-worktrees", "worktrees", "Remove landed worktrees", "Pushed, merged and clean .claude-worktrees.");
  cat("clean-stale-deps", "stale-deps", "Remove stale dependencies", "node_modules / .venv of projects untouched for 30+ days.");

  const poetry = one("poetry", "virtualenvs");
  const orphanedBytes = num(poetry?.data?.orphaned_bytes) ?? 0;
  if (orphanedBytes >= MIN_BYTES) {
    recs.push({
      id: "poetry-envs",
      title: "Remove orphaned Poetry virtualenvs",
      detail: `${num(poetry?.data?.orphaned) ?? "Some"}${num(poetry?.data?.count) !== undefined ? ` of ${num(poetry?.data?.count)}` : ""} envs belong to projects that no longer exist (mostly deleted worktrees).`,
      bytes: orphanedBytes,
      severity: "normal",
      category: "poetry-envs",
    });
  }

  // Worktrees gari will not touch (unmerged, dirty, unpushed) still add up.
  const cleanable = one("clean-worktrees", "worktrees")?.bytes ?? 0;
  const trees = get("wsl-worktrees");
  const treeBytes = sum(trees) - cleanable;
  if (treeBytes >= 5 * GB) {
    recs.push({
      id: "worktrees-manual",
      title: "Review old worktrees by hand",
      detail: `gari only removes landed, clean worktrees. Largest: ${listOf(trees.map((t) => `${short(t.label)} (${human(t.bytes)})`), 3)}. Check for unpushed work, then git worktree remove.`,
      bytes: treeBytes,
      severity: "normal",
    });
  }

  const reclaim = get("docker").reduce((a, d) => a + (num(d.data?.reclaimable) ?? 0), 0);
  if (reclaim >= MIN_BYTES) {
    recs.push({
      id: "docker",
      title: "Prune Docker leftovers",
      detail: "Unused images, stopped containers and build cache.",
      bytes: reclaim,
      severity: "normal",
      category: "docker",
    });
  }
  const anon = one("docker-volumes", "anonymous");
  if (anon && anon.bytes >= MIN_BYTES) {
    recs.push({
      id: "docker-volumes",
      title: "Remove orphaned Docker volumes",
      detail: `${num(anon.data?.count)} anonymous volumes no container uses. Their data is lost, so this is opt-in.`,
      bytes: anon.bytes,
      severity: "normal",
      category: "docker-volumes",
    });
  }
  const named = one("docker-volumes", "named");
  const names = Array.isArray(named?.data?.names) ? (named!.data!.names as unknown[]).map(String) : [];
  if (named && named.bytes >= MIN_BYTES && names.length) {
    recs.push({
      id: "docker-named-volumes",
      title: "Review unused named Docker volumes",
      detail: `Not used by any container, but may hold a stopped stack's data: ${listOf(names)}. Remove with docker volume rm if you no longer need them.`,
      bytes: named.bytes,
      severity: "normal",
    });
  }

  const old = (section: string, id: string, title: string) => {
    const files = get(section).filter((f) => (num(f.data?.age_days) ?? 0) >= OLD_DAYS && !/\.dmp$/i.test(f.label));
    if (sum(files) >= MIN_BYTES) {
      recs.push({
        id,
        title,
        detail: `${listOf(files.map((f) => `${tilde(f.label)} (${human(f.bytes)})`), 3)}. Move what you want to keep to external or cloud storage; delete the rest.`,
        bytes: sum(files),
        severity: "normal",
      });
    }
  };
  old("wsl-big", "old-wsl-files", `WSL: large files untouched for ${OLD_DAYS / 30}+ months`);
  old("win-big", "old-win-files", `Windows: large files untouched for ${OLD_DAYS / 30}+ months`);

  const dumps = get("win-big").filter((f) => /\.dmp$/i.test(f.label));
  if (sum(dumps) >= MIN_BYTES) {
    const byApp = new Map<string, number>();
    for (const f of dumps) byApp.set(appOf(f.label), (byApp.get(appOf(f.label)) ?? 0) + 1);
    recs.push({
      id: "crash-dumps",
      title: "Delete crash dumps",
      detail: `Leftover crash reports from ${listOf([...byApp].map(([a, n]) => `${a} (${n} file${n > 1 ? "s" : ""})`))}. Safe to delete; the paths are in "Windows: files over 500 MB".`,
      bytes: sum(dumps),
      severity: "normal",
    });
  }

  for (const w of get("win-system")) {
    if (w.bytes < 1 * GB) continue;
    const what = /SoftwareDistribution/i.test(w.label) ? "Windows Update cache" : "Temp files";
    recs.push({
      id: `win-system:${w.label}`,
      title: `Clear the ${what}`,
      detail: `${w.label}: run Disk Cleanup → "Clean up system files".`,
      bytes: w.bytes,
      severity: "normal",
    });
  }

  const runtimes = get("win-programs").filter((p) => {
    const m = /\.NET.*Runtime|Desktop Runtime/i.test(p.label) && /(\d+)\.\d+\.\d+/.exec(String(p.data?.version ?? p.label));
    return m && Number(m[1]) < DOTNET_EOL_BELOW;
  });
  if (runtimes.length) {
    recs.push({
      id: "dotnet",
      title: "Uninstall out-of-support .NET runtimes",
      detail: `No longer patched: ${listOf(runtimes.map((p) => p.label))}. Remove from Settings → Apps unless an app still asks for them.`,
      bytes: sum(runtimes),
      severity: "normal",
    });
  }

  recs.sort((a, b) => b.bytes - a.bytes);
  return [...alerts, ...recs];
}
