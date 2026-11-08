// Pure UI state, kept apart from the DOM so it can be tested with node:test.

export type Event =
  | { event: "item" | "removed"; category: string; path: string; bytes: number }
  | { event: "log"; category: string; message: string }
  | { event: "done"; category: string; bytes: number; count: number; error?: string };

export interface CategoryState {
  items: { path: string; bytes: number }[];
  scanned: boolean;
  removed: number;
  freed: number;
  error?: string;
}

export function emptyState(): CategoryState {
  return { items: [], scanned: false, removed: 0, freed: 0 };
}

/** Applies one backend event to the per-category state. */
export function apply(states: Map<string, CategoryState>, e: Event): void {
  const s = states.get(e.category);
  if (!s) return;
  switch (e.event) {
    case "item":
      s.items.push({ path: e.path, bytes: e.bytes });
      break;
    case "removed":
      s.removed += 1;
      s.freed += e.bytes;
      break;
    case "done":
      s.error = e.error;
      // A failed scan is not a scan: nothing it half-listed may be cleaned.
      s.scanned = !e.error;
      if (e.error) s.items = [];
      break;
  }
}

/** The clean allow-list: per finished, successful scan, the paths it showed. */
export function scannedPaths(states: Map<string, CategoryState>, ids: string[]): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const id of ids) {
    const s = states.get(id);
    if (s?.scanned && !s.error) out[id] = s.items.map((i) => i.path);
  }
  return out;
}

export function total(s: CategoryState): number {
  return s.items.reduce((a, i) => a + i.bytes, 0);
}

/**
 * Overall progress for a run: finished steps count fully, the running step counts
 * by how many of its scanned items are gone. Steps with no scan data (or one
 * shot steps like docker) only move when they finish.
 */
export function progress(stepIndex: number, steps: number, current?: CategoryState): number {
  if (steps <= 0) return 0;
  let within = 0;
  if (current && current.items.length) within = Math.min(1, current.removed / current.items.length);
  return Math.min(1, (stepIndex + within) / steps);
}

export function human(bytes: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = bytes;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return i === 0 ? `${bytes} B` : `${v.toFixed(1)} ${units[i]}`;
}

export function ago(tsSeconds: number, nowMs: number): string {
  const s = Math.max(0, Math.floor(nowMs / 1000 - tsSeconds));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  return `${Math.floor(s / 86400)} days ago`;
}
