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

interface Info {
  id: string;
  label: string;
  detail: string;
  disruptive: boolean;
}
interface Run {
  ts: number;
  steps: { category: string; bytes: number; count: number; error?: string }[];
}
interface Step {
  mode: "scan" | "clean" | "sparse";
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

await listen<Step>("gari://step", ({ payload }) => {
  running = payload;
  const info = infos.find((i) => i.id === payload.category);
  const verb = { scan: "Scanning", clean: "Cleaning", sparse: "Enabling auto-shrink:" }[payload.mode];
  stepEl.textContent = `${verb} ${info?.label ?? payload.category} (${payload.index + 1}/${payload.total})`;
  bar.value = progress(payload.index, payload.total);
  updateButtons();
  render();
});

await listen<Event>("gari://event", ({ payload: e }) => {
  apply(states, e);
  if (e.event === "log") log(`[${e.category}] ${e.message}`);
  else if (e.event === "removed") log(`removed ${e.path} (${human(e.bytes)})`);
  else if (e.event === "done" && e.error) log(`[${e.category}] failed: ${e.error}`);
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
        : `Done${failed}`;
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
  if (!i.disruptive) selected.add(i.id);
}
$("subtitle").textContent = `Free up disk space on Windows and WSL (${await invoke<string>("distro")})`;
await loadLastRun();
updateButtons();
render();
