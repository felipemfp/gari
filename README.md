# gari

Windows tray app that frees disk space on a Windows + WSL dev machine. Press **Scan**, tick what to clean, press **Clean**, and watch the progress.

| Category | What goes | Where |
|---|---|---|
| Old worktrees | `.claude-worktrees` that are pushed under their own name, landed on the base branch, and completely clean (ignored files included) | WSL, repos under `~/Workspace` |
| Package & Python caches | npm, pnpm, yarn, pip, uv caches; `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` | WSL |
| Stale deps | `node_modules` / `.venv` whose git repo has no file changed in 30 days | WSL, `~/Workspace` |
| Docker leftovers | `docker system prune -af`: unused images, stopped containers, build cache. **Volumes are never touched.** | Docker Desktop |
| Windows caches | `%LOCALAPPDATA%\npm-cache`, `%LOCALAPPDATA%\pip\Cache` (`%TEMP%` is left alone) | Windows |
| Compact disks | Shrinks the WSL distro and Docker Desktop `.vhdx` files. Asks for admin, **stops Docker Desktop and runs `wsl --shutdown`**, restarts Docker after. Unticked by default. | Windows |

Clean always runs in the order above, so compaction can return the space the other steps freed. **Enable auto-shrink** (footer) turns on sparse VHD for the distro once, so it gives space back by itself from then on.

Closing the window keeps gari in the tray. It also warns you when C: drops below 20 GB free. Each clean run is appended to `%LOCALAPPDATA%\gari\runs.jsonl`.

## Install

Download the `.exe` (NSIS) or `.msi` from the latest GitHub Actions run (artifact `gari-windows`) or from a `v*` release.

## How it works

- `scripts/gari.sh` runs inside WSL (`wsl.exe -d <distro> -- bash -s`, with the script piped in from the binary). Clean gets the exact paths the scan showed you and removes a path only if it is on that list **and** still matches the rules. Anything that showed up after the scan, or stopped qualifying (you touched the project again), is left alone. A failed scan makes nothing in its category cleanable.
- `scripts/vhdx.ps1` handles disk sizing, compaction (`Optimize-VHD`, falling back to `diskpart`) and the sparse switch. Compaction runs elevated and reports through a log file that the app tails.
- `src-tauri/` is the Tauri shell: tray, one run at a time, history, notifications. `ui/` is plain TypeScript.
- Every step speaks the same JSON-lines contract (`item`, `removed`, `log`, `done`), documented at the top of `scripts/gari.sh`.

The worktree rules are vendored from `~/.claude/scripts/wt-cleanup.sh` so gari works on a machine without those dotfiles. If you change the rules in one place, change them in the other.

Env knobs for the WSL script: `GARI_ROOT` (default `~/Workspace`), `GARI_STALE_DAYS` (30), `GARI_DEPTH` (3).

## Develop

```bash
npm ci
npx tauri icon src-tauri/icons/icon.svg -o src-tauri/icons   # icons are generated, not committed
npm test                                                      # bats + cargo test
node --test ui/model.test.ts
npm run tauri dev                                             # Linux/WSL dev run: WSL steps run locally, Windows steps report "only available on Windows"
```

Try the script on its own (read-only):

```bash
bash scripts/gari.sh scan caches | jq .
```

Windows builds come from CI (`.github/workflows/build.yml`).
