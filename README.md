# gari

Windows tray app that frees disk space on a Windows + WSL dev machine. Press **Report** to see where the space goes and what to do about it, **Scan**, tick what to clean, press **Clean**, and watch the progress.

| Category | What goes | Where |
|---|---|---|
| Old worktrees | `.claude-worktrees` that are pushed under their own name, landed on the base branch, and completely clean (ignored files included) | WSL, repos under `~/Workspace` |
| Package & tool caches | npm, pnpm, yarn (incl. berry), bun, pip, uv, poetry caches; Playwright and Cypress browsers (`npx playwright install` brings them back); pre-commit, trivy, node-gyp; VS Code server builds older than the newest that no running process uses; `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` | WSL |
| Stale deps | `node_modules` / `.venv` whose git repo has no file changed in 30 days | WSL, `~/Workspace` |
| Orphaned Poetry envs | `~/.cache/pypoetry/virtualenvs` entries whose project is gone. Orphaned = its name hash (poetry's `generate_env_name`) matches no `pyproject.toml` under `~/Workspace`, its repos' worktrees or `~`, **and** its PEP 610 `direct_url.json` records name project dirs that are all gone. An env with no such record (`package-mode = false`, `--no-root`) is always kept. | WSL |
| Docker leftovers | `docker system prune -af`: unused images, stopped containers, build cache. **Volumes are never touched here.** | Docker Desktop |
| Orphaned Docker volumes | Anonymous volumes (64-hex names) no container references, removed one by one with `docker volume rm`. **Named volumes are never removed** (a stopped compose stack still owns its database); the report lists them for you to review. Opt-in: never ticked by default. | Docker Desktop |
| Windows caches | `%LOCALAPPDATA%\npm-cache`, `%LOCALAPPDATA%\pip\Cache` (`%TEMP%` is left alone) | Windows |
| Compact disks | Shrinks the WSL distro and Docker Desktop `.vhdx` files, see below. Unticked by default. | Windows |

Clean always runs in the order above, so compaction can return the space the other steps freed. **Enable auto-shrink** (footer) turns on sparse VHD for the distro once, so it gives space back by itself from then on.

### Compaction and auto-shrink

Sizes are measured as what a file takes on C: (`GetCompressedFileSizeW`), not its length: Explorer shows a sparse disk's logical size. Reclaimable = that minus the space used inside (`df` in the distro; `docker system df` totals for Docker's disk).

Auto-shrink (sparse VHD) only returns space for blocks Linux discards, in 1 MB-aligned chunks, so a sparse disk still drifts above what it holds. Compaction therefore runs in two stages:

1. **Trim, no admin, nothing shut down.** `fstrim -av` inside the distro that owns each sparse disk, then re-measure. If the gap left is under 2 GiB or under 5% of the data, it stops here.
2. **Full compaction, admin.** Stops Docker Desktop, `wsl --shutdown`, `Optimize-VHD` (or `diskpart`). Optimize-VHD refuses sparse files, so a sparse disk is un-sparsed first and **always re-sparsed after**, even on failure. Un-sparsing fills the file's holes on C:, so each sparse disk is skipped unless C: has that much free plus 5 GB, measured right before it (and before anything is shut down when no disk qualifies). If a sparse compaction fails, its holes stay filled until the next trim, so no further sparse disk is un-sparsed in that run. If the trim stage itself fails, only non-sparse disks are compacted. Docker Desktop is restarted if gari stopped it.

## Report

**Report** (header) measures, read-only: drives; each virtual disk (on disk, data inside, slack, sparse); the top folders of `~`, `~/.cache`, `.claude-worktrees`, the Windows profile and AppData; files over 500 MB; Windows Update cache and temp; installed programs; Docker usage and unused volumes; and what each gari category would free. The Windows side is one walk of the profile that skips junctions and OneDrive cloud-only files.

Recommendations come from fixed thresholds over those numbers (`ui/report.ts`), largest first: compaction slack, caches, orphaned envs and volumes, worktrees gari will not remove itself, large files untouched for 6 months, crash dumps, out-of-support .NET runtimes, a nearly full drive. **Select** on a recommendation ticks the matching category; the rest are things to do by hand.

Closing the window keeps gari in the tray. It also warns you when C: drops below 20 GB free. Each clean run is appended to `%LOCALAPPDATA%\gari\runs.jsonl`.

## Install

Download the `.exe` (NSIS) or `.msi` from the latest GitHub Actions run (artifact `gari-windows`) or from a `v*` release.

## How it works

- `scripts/gari.sh` runs inside WSL (`wsl.exe -d <distro> -- bash -s`, with the script piped in from the binary). Clean gets the exact paths the scan showed you and removes a path only if it is on that list **and** still matches the rules. Anything that showed up after the scan, or stopped qualifying (you touched the project again), is left alone. A failed scan makes nothing in its category cleanable.
- `scripts/vhdx.ps1` handles disk sizing, trim, compaction (`Optimize-VHD`, falling back to `diskpart`), the sparse switch and the Windows half of the report. Compaction runs elevated and reports through a log file that the app tails.
- `src-tauri/` is the Tauri shell: tray, one run at a time, history, notifications. `ui/` is plain TypeScript.
- Every step speaks the same JSON-lines contract (`item`, `removed`, `log`, `done`, plus `stat` for the report), documented at the top of `scripts/gari.sh`.

The worktree rules are vendored from `~/.claude/scripts/wt-cleanup.sh` so gari works on a machine without those dotfiles. If you change the rules in one place, change them in the other.

Env knobs for the WSL script: `GARI_ROOT` (default `~/Workspace`), `GARI_STALE_DAYS` (30), `GARI_DEPTH` (3), `GARI_DOCKER` (docker CLIs to try, one per line; by default `docker`, then Docker Desktop's `docker.exe`, so distros without Docker's WSL integration still work).

## Develop

```bash
npm ci
npx tauri icon src-tauri/icons/icon.svg -o src-tauri/icons   # icons are generated, not committed
npm test                                                      # bats + cargo test
node --test ui/model.test.ts ui/report.test.ts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test\vhdx.tests.ps1   # on Windows (CI runs it)
npm run tauri dev                                             # Linux/WSL dev run: WSL steps run locally, Windows steps report "only available on Windows"
```

Try the script on its own (read-only):

```bash
bash scripts/gari.sh scan caches | jq .
bash scripts/gari.sh report | jq -c 'select(.event=="stat")'
```

Windows builds come from CI (`.github/workflows/build.yml`).
