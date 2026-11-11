#!/usr/bin/env bash
# gari WSL-side cleaner. The Windows app pipes this file to `wsl.exe -- bash -s -- <cmd> <category>`.
#
#   gari.sh scan  <category>          list what would be removed, delete nothing
#   gari.sh clean <category> <list>   remove what is in <list> AND still matches the rules
#   gari.sh report                    read-only disk report: "stat" events, then done
#
# Categories: worktrees, caches, stale-deps, poetry-envs, docker, docker-volumes.
# Output is one JSON object per line on stdout (the app's only contract with this script):
#   {"event":"item","category":C,"path":P,"bytes":N}      scan: one candidate
#   {"event":"removed","category":C,"path":P,"bytes":N}   clean: one candidate gone
#   {"event":"log","category":C,"message":M}              anything worth showing
#   {"event":"done","category":C,"bytes":N,"count":K}     total for the run
#   {"event":"stat","category":"report-wsl","section":S,"label":L,"bytes":N,"data":{..}}
#                                                         report: one measurement
#
# <list> is the file of paths the user saw in the scan (one per line; a Windows
# path is converted with wslpath). Clean re-checks every rule and also requires
# the path to be on the list, so it never deletes something the user was not
# shown, and never something that stopped qualifying since the scan.
#
# Env: GARI_ROOT (default ~/Workspace), GARI_STALE_DAYS (default 30), GARI_DEPTH (default 3),
#      GARI_DOCKER (docker CLIs to try, one per line; default docker, then Docker
#      Desktop's docker.exe for distros without WSL integration).
set -u

ROOT=${GARI_ROOT:-$HOME/Workspace}
STALE_DAYS=${GARI_STALE_DAYS:-30}
DEPTH=${GARI_DEPTH:-3}
DOCKER_CANDIDATES=${GARI_DOCKER:-"docker
docker.exe
/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"}

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}

emit() { # event category path bytes
  printf '{"event":"%s","category":"%s","path":%s,"bytes":%s}\n' "$1" "$2" "$(json_str "$3")" "$4"
}

log() { printf '{"event":"log","category":"%s","message":%s}\n' "$1" "$(json_str "$2")"; }

LIST=
allowed() { [ -n "$LIST" ] && grep -Fxq -- "$1" "$LIST"; }

size_of() { du -sb -- "$1" 2>/dev/null | awk '{print $1+0; f=1} END{if(!f) print 0}'; }

# Git repos under ROOT that own linked worktrees. Prints the main checkout path.
repos() {
  [ -d "$ROOT" ] || return 0
  find "$ROOT" -maxdepth "$DEPTH" \( -name node_modules -o -name .venv \) -prune -o -type d -name .git -print 2>/dev/null |
    while read -r g; do dirname "$g"; done
}

# ---- worktrees -------------------------------------------------------------
# Same rules as ~/.claude/scripts/wt-cleanup.sh (vendored on purpose, see README):
# only .claude-worktrees, pushed under their own name, landed on the base, and
# nothing at all left in the tree, ignored files included.
candidates_worktrees() {
  repos | while read -r repo; do
    base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD) || continue
    git -C "$repo" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' |
      grep "/\.claude-worktrees/" | while read -r w; do
        [ -d "$w" ] || continue
        b=$(git -C "$w" branch --show-current 2>/dev/null); [ -n "$b" ] || continue
        up=$(git -C "$w" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
        [ "$up" = "origin/$b" ] || continue
        git -C "$repo" merge-base --is-ancestor "$b" "$base" \
          || [ -z "$(git -C "$repo" cherry "$base" "$b" | grep '^+')" ] || continue
        [ -n "$(git -C "$w" status --porcelain --ignored)" ] && continue
        printf '%s\t%s\n' "$repo" "$w"
      done
  done
}

scan_worktrees() { candidates_worktrees | while IFS=$'\t' read -r _ w; do printf '%s\t%s\n' "$(size_of "$w")" "$w"; done; }

remove_worktrees() {
  candidates_worktrees | while IFS=$'\t' read -r repo w; do
    allowed "$w" || continue
    n=$(size_of "$w")
    if git -C "$repo" worktree remove "$w" 2>/dev/null; then
      printf '%s\t%s\n' "$n" "$w"
    else
      log worktrees "skipped $w: git worktree remove refused" >&2
    fi
  done
  repos | while read -r repo; do git -C "$repo" worktree prune 2>/dev/null; done
}

# ---- caches ----------------------------------------------------------------
# Package-manager and tool caches (all re-downloadable), superseded VS Code
# server builds, and Python tool caches in projects.
CACHE_DIRS=(
  .npm/_cacache .cache/pip .cache/uv .cache/yarn .yarn/berry/cache .cache/pnpm
  .local/share/pnpm/store .bun/install/cache .cache/pypoetry/cache
  .cache/pypoetry/artifacts .cache/pre-commit .cache/ms-playwright .cache/Cypress
  .cache/trivy .cache/node-gyp
)

# Every VS Code server build but the newest, unless a running process uses it
# (an older window can still be attached to an older build).
vscode_old_builds() {
  local base n d running
  running=$(ps -eo args= 2>/dev/null)
  for base in "$HOME/.vscode-server/bin" "$HOME/.vscode-server/cli/servers"; do
    [ -d "$base" ] || continue
    # shellcheck disable=SC2012  # build dirs are hex/Stable-<hex>, no odd names
    ls -1t "$base" | {
    newest=1
    while read -r n; do
      d="$base/$n"
      [ -d "$d" ] || continue
      if [ "$newest" = 1 ]; then newest=0; continue; fi
      case $running in *"$d"*) continue ;; esac
      printf '%s\n' "$d"
    done
    }
  done
}

cache_dirs() {
  local d
  for d in "${CACHE_DIRS[@]}"; do
    [ -d "$HOME/$d" ] && printf '%s\n' "$HOME/$d"
  done
  vscode_old_builds
  [ -d "$ROOT" ] || return 0
  find "$ROOT" \( -name node_modules -o -name .venv -o -name .git \) -prune -o \
    -type d \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache \) \
    -print -prune 2>/dev/null
}

scan_caches() { cache_dirs | while read -r d; do printf '%s\t%s\n' "$(size_of "$d")" "$d"; done; }

remove_caches() {
  cache_dirs | while read -r d; do
    allowed "$d" || continue
    n=$(size_of "$d")
    rm -rf -- "$d" && printf '%s\t%s\n' "$n" "$d"
  done
}

# ---- stale-deps ------------------------------------------------------------
# node_modules / .venv whose project has no file modified in STALE_DAYS days.
# The project is the enclosing git repo (so a generated subfolder like
# .react-email does not look abandoned while its repo is in use), else the
# deps dir's parent. Deps dirs and .git never count as activity.
dep_dirs() {
  [ -d "$ROOT" ] || return 0
  find "$ROOT" -name .git -prune -o -type d \( -name node_modules -o -name .venv \) -print -prune 2>/dev/null |
    while read -r d; do
      p=$(git -C "$(dirname "$d")" rev-parse --show-toplevel 2>/dev/null) || p=$(dirname "$d")
      # Any find error (unreadable dir, broken mount) means "unknown", never "stale".
      fresh=$(find "$p" \( -name node_modules -o -name .venv -o -name .git \) -prune -o \
        -type f -mtime "-$STALE_DAYS" -print -quit 2>/dev/null) || continue
      [ -z "$fresh" ] && printf '%s\n' "$d"
    done
}

scan_stale_deps() { dep_dirs | while read -r d; do printf '%s\t%s\n' "$(size_of "$d")" "$d"; done; }

remove_stale_deps() {
  dep_dirs | while read -r d; do
    allowed "$d" || continue
    n=$(size_of "$d")
    rm -rf -- "$d" && printf '%s\t%s\n' "$n" "$d"
  done
}

# ---- poetry-envs -------------------------------------------------------------
# Poetry keeps project virtualenvs in ~/.cache/pypoetry/virtualenvs, named
# <name>-<hash>-py<ver>, where <hash> is the first 8 chars of the urlsafe base64
# sha256 of the project's real path (poetry's generate_env_name). An env is
# orphaned only when no pyproject.toml we can find hashes to it (typically its
# worktree was deleted) AND its own install records (PEP 610 direct_url.json)
# name project dirs that are all gone. An env with no such record is kept:
# nothing proves its project is gone. Envs are rebuilt by `poetry install`.
POETRY_ENVS="$HOME/.cache/pypoetry/virtualenvs"

poetry_hash() { # dir -> 8 char poetry env hash
  local hex
  hex=$(printf '%s' "$1" | sha256sum | cut -c1-64)
  # shellcheck disable=SC2059  # the format IS the data: \xNN escapes to bytes
  printf "$(printf '%s' "$hex" | sed 's/../\\x&/g')" | base64 -w0 | tr '+/' '-_' | cut -c1-8
}

# Project dirs to search: the workspace, every worktree of its repos (they live
# outside ROOT), and shallow home dirs.
poetry_projects() {
  {
    [ -d "$ROOT" ] && printf '%s\t%s\n' "$ROOT" $((DEPTH + 2))
    repos | while read -r repo; do
      git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' |
        while read -r w; do printf '%s\t%s\n' "$w" 4; done
    done
    printf '%s\t%s\n' "$HOME" 3
  } | while IFS=$'\t' read -r dir depth; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth "$depth" \( -name node_modules -o -name .venv -o -name .git -o -name .cache \) -prune \
      -o -name pyproject.toml -print 2>/dev/null
  done | while read -r f; do realpath -- "$(dirname "$f")"; done | sort -u
}

orphan_poetry_envs() {
  [ -d "$POETRY_ENVS" ] || return 0
  local live h e
  live=$(poetry_projects | while read -r p; do poetry_hash "$p"; done)
  for e in "$POETRY_ENVS"/*/; do
    e=${e%/}
    [ -d "$e" ] || continue
    # Unknown naming: not ours to judge.
    h=$(basename "$e" | sed -nE 's/.*-([A-Za-z0-9_-]{8})-py[0-9]+\.[0-9]+$/\1/p')
    [ -n "$h" ] || continue
    printf '%s\n' "$live" | grep -Fxq -- "$h" && continue
    # Poetry installs the root project editable; its direct_url.json names the
    # project dir. If it names any, they decide: one still there keeps the env.
    local from p alive=0
    from=$(env_projects "$e")
    if [ -n "$from" ]; then
      while read -r p; do [ -e "$p" ] && alive=1; done <<<"$from"
      [ "$alive" = 0 ] && printf '%s\n' "$e"
      continue
    fi
    # No record of its project (package-mode = false, --no-root): we cannot
    # prove the project is gone, and age says nothing about use, so keep it.
  done
}

# Local dirs an env installed packages from (PEP 610 direct_url.json, file:// urls).
env_projects() {
  find "$1" -maxdepth 6 -path '*site-packages/*.dist-info/direct_url.json' -print0 2>/dev/null |
    xargs -0 -r grep -ho '"url": *"file://[^"]*"' 2>/dev/null |
    sed -E 's/.*"file:\/\/([^"]*)"/\1/' | while read -r u; do printf '%b\n' "${u//%/\\x}"; done | sort -u
}

scan_poetry_envs() { orphan_poetry_envs | while read -r d; do printf '%s\t%s\n' "$(size_of "$d")" "$d"; done; }

remove_poetry_envs() {
  orphan_poetry_envs | while read -r d; do
    allowed "$d" || continue
    n=$(size_of "$d")
    rm -rf -- "$d" && printf '%s\t%s\n' "$n" "$d"
  done
}

# ---- docker ----------------------------------------------------------------
# docker: unused images, stopped containers, build cache (docker system prune).
# docker-volumes: anonymous volumes no container references. Named volumes are
# never touched: a compose stack that is down still owns its database volume.
si_bytes() { # "1.5GB" -> bytes; docker prints SI units
  local v=${1%% *}
  v=${v%B}; v=${v/k/K}
  [ -z "$v" ] && { echo 0; return; }
  numfmt --from=si "$v" 2>/dev/null || echo 0
}

DOCKER=
# First CLI that reaches a daemon. A distro without Docker Desktop's WSL
# integration has no `docker`, but Windows interop can still run docker.exe.
docker_ok() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    command -v "$d" >/dev/null 2>&1 || [ -x "$d" ] || continue
    if timeout 15 "$d" info >/dev/null 2>&1; then DOCKER=$d; return 0; fi
  done <<<"$DOCKER_CANDIDATES"
  return 1
}

dk() { "$DOCKER" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }

scan_docker() {
  docker_ok || { log docker "docker is not running, skipped" >&2; return 0; }
  dk system df --format '{{.Type}}\t{{.Reclaimable}}' | while IFS=$'\t' read -r t r; do
    case $t in Images|Containers|"Build Cache") printf '%s\tdocker: %s\n' "$(si_bytes "$r")" "$t" ;; esac
  done
}

remove_docker() {
  grep -q '^docker: ' "$LIST" 2>/dev/null || return 0
  docker_ok || { log docker "docker is not running, skipped" >&2; return 0; }
  out=$(dk system prune -af)
  total=$(printf '%s\n' "$out" | sed -n 's/^Total reclaimed space: //p')
  printf '%s\tdocker system prune -af\n' "$(si_bytes "${total:-0B}")"
}

# "<name> <links> <size>" per volume. No quotes or tabs in the template: they do
# not survive the trip through docker.exe's Windows command line.
docker_volumes() {
  dk system df -v --format '{{range .Volumes}}{{.Name}} {{.Links}} {{.Size}}{{println}}{{end}}'
}

# Unreferenced anonymous volumes: "<bytes>\tdocker volume: <name>".
orphan_volumes() {
  docker_volumes | while read -r name links size; do
    [ "$links" = 0 ] || continue
    [[ $name =~ ^[0-9a-f]{64}$ ]] || continue
    printf '%s\tdocker volume: %s\n' "$(si_bytes "$size")" "$name"
  done
}

scan_docker_volumes() {
  docker_ok || { log docker-volumes "docker is not running, skipped" >&2; return 0; }
  orphan_volumes
}

remove_docker_volumes() {
  docker_ok || { log docker-volumes "docker is not running, skipped" >&2; return 0; }
  orphan_volumes | while IFS=$'\t' read -r n p; do
    allowed "$p" || continue
    # `volume rm` (not prune) refuses a volume a container started using since.
    if dk volume rm "${p#docker volume: }" >/dev/null; then
      printf '%s\t%s\n' "$n" "$p"
    else
      log docker-volumes "skipped ${p#docker volume: }: docker refused to remove it" >&2
    fi
  done
}

# ---- report ----------------------------------------------------------------
# Read-only measurements for the app's disk report. Paths, never contents.
stat_line() { # section label bytes [data-json]
  printf '{"event":"stat","category":"report-wsl","section":"%s","label":%s,"bytes":%s,"data":%s}\n' \
    "$1" "$(json_str "$2")" "${3:-0}" "${4:-null}"
}

top_under() { # section limit parent  (reads "bytes\tpath" lines of $DU)
  local section=$1 limit=$2 parent=$3
  printf '%s\n' "$DU" | awk -F'\t' -v p="$parent/" 'index($2, p) == 1 && index(substr($2, length(p) + 1), "/") == 0' |
    sort -rn | head -n "$limit" | while IFS=$'\t' read -r n p; do stat_line "$section" "$p" "$n"; done
}

report() {
  local used size avail
  read -r size used avail < <(df -B1 --output=size,used,avail / | tail -1)
  stat_line wsl-df / "$used" "{\"size\":$size,\"avail\":$avail}"

  # One du over home; every per-folder total below comes from it.
  DU=$(du -xb -d3 "$HOME" 2>/dev/null)
  top_under wsl-home 15 "$HOME"
  top_under wsl-cache 12 "$HOME/.cache"
  top_under wsl-worktrees 12 "$HOME/.claude-worktrees"

  # Big files: size, last change (days), path.
  find "$HOME" -xdev -type f -size +500M -printf '%s\t%T@\t%p\n' 2>/dev/null | sort -rn | head -20 |
    while IFS=$'\t' read -r n t p; do
      stat_line wsl-big "$p" "$n" "{\"age_days\":$(( ($(date +%s) - ${t%.*}) / 86400 ))}"
    done

  # Same rules as the clean steps, so the report and the cleaner agree.
  local c n
  c=0; n=0
  while IFS=$'\t' read -r b _; do c=$((c + 1)); n=$((n + b)); done < <(scan_caches)
  stat_line clean-caches caches "$n" "{\"count\":$c}"
  c=0; n=0
  while IFS=$'\t' read -r b _; do c=$((c + 1)); n=$((n + b)); done < <(scan_poetry_envs)
  local all=0 envs=0
  if [ -d "$POETRY_ENVS" ]; then
    envs=$(find "$POETRY_ENVS" -mindepth 1 -maxdepth 1 -type d | wc -l)
    all=$(printf '%s\n' "$DU" | awk -F'\t' -v p="$POETRY_ENVS" '$2 == p {print $1}')
    [ -n "$all" ] || all=$(size_of "$POETRY_ENVS")
  fi
  stat_line poetry "virtualenvs" "$all" "{\"count\":$envs,\"orphaned\":$c,\"orphaned_bytes\":$n}"
  c=0; n=0
  while IFS=$'\t' read -r b _; do c=$((c + 1)); n=$((n + b)); done < <(scan_stale_deps)
  stat_line clean-stale-deps stale-deps "$n" "{\"count\":$c}"
  c=0; n=0
  while IFS=$'\t' read -r b _; do c=$((c + 1)); n=$((n + b)); done < <(scan_worktrees)
  stat_line clean-worktrees worktrees "$n" "{\"count\":$c}"

  if docker_ok; then
    dk system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' | while IFS=$'\t' read -r t s r; do
      stat_line docker "$t" "$(si_bytes "$s")" "{\"reclaimable\":$(si_bytes "$r")}"
    done
    local anon=0 anon_n=0 named=0 named_n=0 names=()
    while read -r name links size; do
      [ "$links" = 0 ] || continue
      b=$(si_bytes "$size")
      if [[ $name =~ ^[0-9a-f]{64}$ ]]; then anon=$((anon + b)); anon_n=$((anon_n + 1))
      else named=$((named + b)); named_n=$((named_n + 1)); names+=("$(json_str "$name")"); fi
    done < <(docker_volumes)
    local joined
    joined=$(IFS=,; printf '%s' "${names[*]}")
    stat_line docker-volumes anonymous "$anon" "{\"count\":$anon_n}"
    stat_line docker-volumes named "$named" "{\"count\":$named_n,\"names\":[${joined}]}"
  else
    log report-wsl "docker is not running; docker numbers left out"
  fi
  printf '{"event":"done","category":"report-wsl","bytes":0,"count":0}\n'
}

# ---- main ------------------------------------------------------------------
run() { # cmd category [list]
  local cmd=$1 cat=$2 fn ev total=0 count=0
  case $cat in worktrees|caches|stale-deps|poetry-envs|docker|docker-volumes) ;; *) echo "unknown category: $cat" >&2; return 2 ;; esac
  case $cmd in scan) fn=scan_ ev=item ;; clean) fn=remove_ ev=removed ;; *) echo "unknown command: $cmd" >&2; return 2 ;; esac
  fn=$fn${cat//-/_}
  if [ "$cmd" = clean ]; then
    LIST=${3:-}
    case $LIST in *\\* | [A-Za-z]:/*) LIST=$(wslpath -u "$LIST") ;; esac
    [ -f "$LIST" ] || { echo "clean needs the scanned list file" >&2; return 2; }
  fi
  # stderr of the generators carries log events (and stray tool noise); fold it in.
  while IFS= read -r line; do
    case $line in
      '{'*) printf '%s\n' "$line"; continue ;;
      [0-9]*$'\t'*) n=${line%%$'\t'*}; p=${line#*$'\t'} ;;
      *) log "$cat" "$line"; continue ;;
    esac
    emit "$ev" "$cat" "$p" "$n"
    total=$((total + n)); count=$((count + 1))
  done < <("$fn" 2>&1)
  printf '{"event":"done","category":"%s","bytes":%s,"count":%s}\n' "$cat" "$total" "$count"
}

if [ $# -eq 1 ] && [ "$1" = report ]; then
  report
  exit 0
fi
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: gari.sh scan <category> | gari.sh clean <category> <list-file> | gari.sh report" >&2
  exit 2
fi
run "$@"
