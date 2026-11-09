#!/usr/bin/env bash
# gari WSL-side cleaner. The Windows app pipes this file to `wsl.exe -- bash -s -- <cmd> <category>`.
#
#   gari.sh scan  <category>          list what would be removed, delete nothing
#   gari.sh clean <category> <list>   remove what is in <list> AND still matches the rules
#
# Categories: worktrees, caches, stale-deps, docker.
# Output is one JSON object per line on stdout (the app's only contract with this script):
#   {"event":"item","category":C,"path":P,"bytes":N}      scan: one candidate
#   {"event":"removed","category":C,"path":P,"bytes":N}   clean: one candidate gone
#   {"event":"log","category":C,"message":M}              anything worth showing
#   {"event":"done","category":C,"bytes":N,"count":K}     total for the run
#
# <list> is the file of paths the user saw in the scan (one per line; a Windows
# path is converted with wslpath). Clean re-checks every rule and also requires
# the path to be on the list, so it never deletes something the user was not
# shown, and never something that stopped qualifying since the scan.
#
# Env: GARI_ROOT (default ~/Workspace), GARI_STALE_DAYS (default 30), GARI_DEPTH (default 3).
set -u

ROOT=${GARI_ROOT:-$HOME/Workspace}
STALE_DAYS=${GARI_STALE_DAYS:-30}
DEPTH=${GARI_DEPTH:-3}

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
# Package-manager caches (all re-downloadable) and Python tool caches in projects.
cache_dirs() {
  for d in "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/yarn" \
           "$HOME/.cache/pnpm" "$HOME/.local/share/pnpm/store"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
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

# ---- docker ----------------------------------------------------------------
# Unused images, stopped containers, build cache. Volumes are never touched.
si_bytes() { # "1.5GB" -> bytes; docker prints SI units
  local v=${1%% *}
  v=${v%B}; v=${v/k/K}
  [ -z "$v" ] && { echo 0; return; }
  numfmt --from=si "$v" 2>/dev/null || echo 0
}

docker_ok() { command -v docker >/dev/null 2>&1 && timeout 15 docker info >/dev/null 2>&1; }

scan_docker() {
  docker_ok || { log docker "docker is not running, skipped" >&2; return 0; }
  docker system df --format '{{.Type}}\t{{.Reclaimable}}' | while IFS=$'\t' read -r t r; do
    case $t in Images|Containers|"Build Cache") printf '%s\tdocker: %s\n' "$(si_bytes "$r")" "$t" ;; esac
  done
}

remove_docker() {
  grep -q '^docker: ' "$LIST" 2>/dev/null || return 0
  docker_ok || { log docker "docker is not running, skipped" >&2; return 0; }
  out=$(docker system prune -af 2>&1)
  total=$(printf '%s\n' "$out" | sed -n 's/^Total reclaimed space: //p')
  printf '%s\tdocker system prune -af\n' "$(si_bytes "${total:-0B}")"
}

# ---- main ------------------------------------------------------------------
run() { # cmd category [list]
  local cmd=$1 cat=$2 fn ev total=0 count=0
  case $cat in worktrees|caches|stale-deps|docker) ;; *) echo "unknown category: $cat" >&2; return 2 ;; esac
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

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: gari.sh scan <category> | gari.sh clean <category> <list-file>" >&2
  exit 2
fi
run "$@"
