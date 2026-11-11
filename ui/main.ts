import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  ago,
  apply,
  emptyState,
  human,
  progress,
  scannedPaths,
  total,
  type CategoryState,
  type Event,
} from "./model.ts";
import { collect, diskName, recommend, type Rec, type Stat } from "./report.ts";

interface Info {
  id: string;
  label: string;
  detail: string;
  disruptive: boolean;
  opt_in: boolean;
}
interface Run {
  ts: number;
  steps: { category: string; bytes: number; count: number; error?: string }[];
}
interface Step {
  mode: "scan" | "clean" | "sparse" | "report";
  index: number;
  total: number;
  category: string;
}
interface Finished {
  mode: Step["mode"];
  freed: number;
  errors: string[];
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const scanBtn = $<HTMLButtonElement>("scan");
const cleanBtn = $<HTMLButtonElement>("clean");
const sparseBtn = $<HTMLButtonElement>("sparse");
const reportBtn = $<HTMLButtonElement>("report-btn");
const reportBox = $("report");
const list = $("categories");
const statusBox = $("status");
const stepEl = $("step");
const freedEl = $("freed");
const bar = $<HTMLProgressElement>("progress");
const logEl = $("log");

let infos: Info[] = [];
const states = new Map<string, CategoryState>();
const selected = new Set<string>();
let running: Step | null = null;
let lastRunIds: string[] = [];
let stats: Stat[] = [];

function log(line: string) {
  const atBottom = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 4;
  logEl.textContent += line + "\n";
  if (atBottom) logEl.scrollTop = logEl.scrollHeight;
}

function render() {
  list.replaceChildren(
    ...infos.map((info) => {
      const s = states.get(info.id)!;
      const row = document.createElement("details");
      row.className = "cat" + (running?.category === info.id ? " active" : "");
      const sum = document.createElement("summary");

      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = selected.has(info.id);
      box.disabled = !!running;
      box.addEventListener("click", (e) => e.stopPropagation());
      box.addEventListener("change", () => {
        box.checked ? selected.add(info.id) : selected.delete(info.id);
        updateButtons();
      });

      const text = document.createElement("div");
      text.className = "text";
      const label = document.createElement("strong");
      label.textContent = info.label + (info.disruptive ? " ⚠" : "");
      const detail = document.createElement("span");
      detail.className = "muted";
      detail.textContent = info.detail;
      text.append(label, detail);

      const size = document.createElement("span");
      size.className = "size";
      if (s.error) size.textContent = "failed";
      else if (s.freed) size.textContent = `freed ${human(s.freed)}`;
      else if (s.scanned) size.textContent = (info.id === "vhdx" ? "≈ " : "") + human(total(s));
      else size.textContent = "—";
      if (s.error) size.title = s.error;

      sum.append(box, text, size);
      row.append(sum);

      const ul = document.createElement("ul");
      const items = [...s.items].sort((a, b) => b.bytes - a.bytes);
      for (const it of items.slice(0, 200)) {
        const li = document.createElement("li");
        li.innerHTML = "<span></span><span></span>";
        li.children[0].textContent = it.path;
        li.children[1].textContent = human(it.bytes);
        ul.append(li);
      }
      if (items.length > 200) {
        const li = document.createElement("li");
        li.textContent = `…and ${items.length - 200} more`;
        ul.append(li);
      }
      if (!items.length) {
        const li = document.createElement("li");
        li.className = "muted";
        li.textContent = s.scanned ? "Nothing to clean." : "Not scanned yet.";
        ul.append(li);
      }
      row.append(ul);
      return row;
    }),
  );
}

function updateButtons() {
  scanBtn.disabled = !!running;
  sparseBtn.disabled = !!running;
  reportBtn.disabled = !!running;
  const ready = [...selected].some((id) => states.get(id)?.scanned);
  cleanBtn.disabled = !!running || !ready;
}

async function loadLastRun() {
  const run = await invoke<Run | null>("last_run");
  const el = $("last-run");
  if (!run) {
    el.textContent = "No cleanup yet.";
    return;
  }
  const freed = run.steps.reduce((a, s) => a + s.bytes, 0);
  el.textContent = `Last cleanup ${ago(run.ts, Date.now())}: freed ${human(freed)}`;
}

async function start(mode: "scan" | "clean", ids: string[]) {
  statusBox.hidden = false;
  logEl.textContent = "";
  freedEl.textContent = "";
  bar.value = 0;
  lastRunIds = ids;
  for (const id of ids) {
    const s = states.get(id)!;
    if (mode === "scan") states.set(id, emptyState());
    else Object.assign(s, { removed: 0, freed: 0, error: undefined });
  }
  try {
    // Clean gets the exact paths the user saw; the backend deletes nothing else.
    const scanned = mode === "clean" ? scannedPaths(states, ids) : null;
    await invoke("start", { mode, categories: ids, scanned });
  } catch (e) {
    log(`error: ${e}`);
  }
}

scanBtn.addEventListener("click", () => start("scan", infos.map((i) => i.id)));

cleanBtn.addEventListener("click", () => {
  const ids = infos.map((i) => i.id).filter((id) => selected.has(id) && states.get(id)?.items.length);
  if (!ids.length) return alert("Nothing to clean in the selected categories.");
  const bytes = ids.reduce((a, id) => a + total(states.get(id)!), 0);
  let msg = `Clean ${ids.length} categor${ids.length === 1 ? "y" : "ies"} (about ${human(bytes)})?`;
  if (ids.includes("vhdx"))
    msg += "\n\nDisk compaction shuts down WSL and Docker Desktop (every WSL terminal and container stops) and asks for admin.";
  if (confirm(msg)) start("clean", ids);
});

sparseBtn.addEventListener("click", async () => {
  if (!confirm("Enable auto-shrink (sparse VHD) for the WSL disk? This shuts down WSL and asks for admin.")) return;
  statusBox.hidden = false;
  logEl.textContent = "";
  try {
    await invoke("enable_sparse");
  } catch (e) {
    log(`error: ${e}`);
  }
});

reportBtn.addEventListener("click", async () => {
  stats = [];
  statusBox.hidden = false;
  logEl.textContent = "";
  freedEl.textContent = "";
  bar.value = 0;
  try {
    await invoke("report");
  } catch (e) {
    log(`error: ${e}`);
  }
});

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};

function kpi(title: string, value: string, note: string, ratio?: number, bad = false) {
  const k = el("div", "kpi" + (bad ? " bad" : ""));
  k.append(el("span", "muted", title), el("b", undefined, value));
  if (ratio !== undefined) {
    const m = el("div", "meter");
    const i = el("i");
    i.style.width = `${Math.round(Math.min(1, Math.max(0, ratio)) * 100)}%`;
    m.append(i);
    k.append(m);
  }
  k.append(el("span", "muted", note));
  return k;
}

/** Ticks a category in the cleaner and scrolls to it. */
function pick(id: string) {
  selected.add(id);
  updateButtons();
  render();
  const row = [...list.children].find((_, i) => infos[i]?.id === id) as HTMLElement | undefined;
  if (row) {
    row.scrollIntoView({ behavior: "smooth", block: "center" });
    row.classList.add("flash");
    setTimeout(() => row.classList.remove("flash"), 1500);
  }
  stepEl.textContent = "Selected. Press Scan, then Clean selected.";
  statusBox.hidden = false;
}

function recRow(r: Rec) {
  const li = el("li", "rec" + (r.severity === "high" ? " high" : ""));
  const text = el("div", "text");
  text.append(el("strong", undefined, r.title), el("span", "muted", r.detail));
  li.append(text, el("span", "size", r.bytes ? human(r.bytes) : ""));
  if (r.category && infos.some((i) => i.id === r.category)) {
    const b = el("button", undefined, selected.has(r.category) ? "Selected" : "Select");
    b.title = "Tick this in the cleaner below";
    b.addEventListener("click", () => {
      pick(r.category!);
      b.textContent = "Selected";
    });
    li.append(b);
  } else if (r.action === "sparse") {
    const b = el("button", undefined, "Enable");
    b.addEventListener("click", () => sparseBtn.click());
    li.append(b);
  }
  return li;
}

const SECTIONS: [string, string][] = [
  ["wsl-home", "WSL: home folder"],
  ["wsl-cache", "WSL: ~/.cache"],
  ["wsl-worktrees", "WSL: .claude-worktrees"],
  ["wsl-big", "WSL: files over 500 MB"],
  ["docker", "Docker"],
  ["win-profile", "Windows: user folder"],
  ["win-appdata", "Windows: AppData"],
  ["win-big", "Windows: files over 500 MB"],
  ["win-system", "Windows: system caches"],
  ["win-programs", "Windows: installed programs"],
];

function note(section: string, s: Stat): string {
  const d = s.data ?? {};
  if (typeof d.age_days === "number") return `${d.age_days} days old`;
  if (section === "win-programs") return [d.version, d.installed].filter(Boolean).join(" · ");
  if (section === "docker" && typeof d.reclaimable === "number") return `${human(d.reclaimable)} reclaimable`;
  return "";
}

function renderReport() {
  if (!stats.length) return;
  const r = collect(stats);
  reportBox.hidden = false;
  $("report-when").textContent = `measured ${new Date().toLocaleTimeString()}`;

  const kpis: HTMLElement[] = [];
  for (const d of r.get("win-drive") ?? []) {
    const size = Number(d.data?.size ?? 0);
    const free = Number(d.data?.free ?? 0);
    const ratio = size ? d.bytes / size : 0;
    kpis.push(kpi(`Windows ${d.label}`, `${Math.round(ratio * 100)}% full`, `${human(free)} free of ${human(size)}`, ratio, ratio > 0.9 || free < 20e9));
  }
  const wsl = r.get("wsl-df")?.[0];
  if (wsl) kpis.push(kpi("Inside WSL", human(wsl.bytes), "used by files in the distro"));
  for (const v of r.get("vhdx") ?? []) {
    const used = typeof v.data?.used === "number" ? v.data.used : undefined;
    const slack = used !== undefined ? Math.max(0, v.bytes - used) : undefined;
    kpis.push(
      kpi(
        `${diskName(v.label)} disk on C:`,
        human(v.bytes),
        (used !== undefined ? `${human(used)} of data, ${human(slack!)} slack` : "data inside unknown (Docker stopped?)") +
          (v.data?.sparse ? " · auto-shrink on" : ""),
        used !== undefined && v.bytes ? used / v.bytes : undefined,
        (slack ?? 0) > 2 * 2 ** 30,
      ),
    );
  }
  $("kpis").replaceChildren(...kpis);

  const recs = recommend(r);
  $("recs").replaceChildren(...(recs.length ? recs.map(recRow) : [el("li", "muted", "Nothing worth doing. Disk use looks healthy.")]));

  const details = SECTIONS.filter(([id]) => r.get(id)?.length).map(([id, title]) => {
    const rows = [...r.get(id)!].sort((a, b) => b.bytes - a.bytes);
    const box = el("details");
    box.append(el("summary", undefined, `${title} (${rows.length})`));
    const table = el("table");
    for (const s of rows) {
      const tr = el("tr");
      tr.append(el("td", undefined, s.label), el("td", "n muted", note(id, s)), el("td", "n", human(s.bytes)));
      table.append(tr);
    }
    box.append(table);
    return box;
  });
  $("report-details").replaceChildren(...details);
}

await listen<Step>("gari://step", ({ payload }) => {
  running = payload;
  const info = infos.find((i) => i.id === payload.category);
  const verb = { scan: "Scanning", clean: "Cleaning", sparse: "Enabling auto-shrink:", report: "Measuring" }[payload.mode];
  const what = { "report-wsl": "WSL (a minute or two)", "report-win": "Windows" }[payload.category];
  stepEl.textContent = `${verb} ${what ?? info?.label ?? payload.category} (${payload.index + 1}/${payload.total})`;
  bar.value = progress(payload.index, payload.total);
  updateButtons();
  render();
});

await listen<Event | ({ event: "stat"; category: string } & Stat)>("gari://event", ({ payload: e }) => {
  if (e.event === "stat") {
    stats.push(e);
    return;
  }
  apply(states, e);
  if (e.event === "log") log(`[${e.category}] ${e.message}`);
  else if (e.event === "removed") log(`removed ${e.path} (${human(e.bytes)})`);
  else if (e.event === "done" && e.error) log(`[${e.category}] failed: ${e.error}`);
  else if (e.event === "done" && running?.mode === "report") log(`[${e.category}] measured`);
  else if (e.event === "done") log(`[${e.category}] ${running?.mode === "clean" ? "freed" : "found"} ${human(e.bytes)}`);
  if (running) bar.value = progress(running.index, running.total, states.get(running.category));
  if (running?.mode === "clean") {
    const freed = [...states.values()].reduce((a, s) => a + s.freed, 0);
    freedEl.textContent = `freed ${human(freed)}`;
  }
  if (e.event !== "log") render();
});

await listen<Finished>("gari://finished", async ({ payload }) => {
  running = null;
  bar.value = 1;
  const failed = payload.errors.length ? ` — ${payload.errors.length} failed` : "";
  stepEl.textContent =
    payload.mode === "clean"
      ? `Done. Freed ${human(payload.freed)}${failed}`
      : payload.mode === "scan"
        ? `Scan done. Select what to clean.${failed}`
        : payload.mode === "report"
          ? `Report ready.${failed}`
          : `Done${failed}`;
  if (payload.mode === "report") renderReport();
  try {
    if (payload.mode === "clean") {
      // What was cleaned is gone; sizes are stale until the next scan.
      for (const id of lastRunIds) {
        const s = states.get(id)!;
        if (!s.error) states.set(id, { ...emptyState(), freed: s.freed });
      }
      await loadLastRun();
    }
  } catch (e) {
    log(`could not load run history: ${e}`);
  } finally {
    updateButtons();
    render();
  }
});

infos = await invoke<Info[]>("categories");
for (const i of infos) {
  states.set(i.id, emptyState());
  if (!i.disruptive && !i.opt_in) selected.add(i.id);
}
$("subtitle").textContent = `Free up disk space on Windows and WSL (${await invoke<string>("distro")})`;
await loadLastRun();
updateButtons();
render();
