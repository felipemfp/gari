#!/usr/bin/env bats
# Fixture tests for scripts/gari.sh. Each test builds a fake HOME and workspace.
# Failure modes covered before the script was written:
#   - clean deletes something scan did not list (or misses something it listed)
#   - a worktree with work in it (unpushed, unmerged, dirty, ignored files) is removed
#   - fresh node_modules/.venv removed; deps inside other deps double counted
#   - caches inside node_modules/.git touched
#   - docker volumes pruned, docker down breaks the run, size units misparsed
#   - output that is not one JSON object per line

GARI="$BATS_TEST_DIRNAME/../scripts/gari.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export GARI_ROOT="$HOME/Workspace"
  mkdir -p "$GARI_ROOT"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_NOSYSTEM=1
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
  # No real docker unless a test installs a fake one.
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/docker"; chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

LIST="$BATS_TEST_TMPDIR/list"

# scan: paths() scan <cat> item. clean: paths() clean <cat> removed, using the
# list written by the most recent scan_list (what the UI sends back).
paths() {
  if [ "$1" = clean ]; then
    bash "$GARI" clean "$2" "$LIST" | jq -r --arg e "$3" 'select(.event==$e) | .path' | sort
  else
    bash "$GARI" "$1" "$2" | jq -r --arg e "$3" 'select(.event==$e) | .path' | sort
  fi
}

scan_list() { # category -> writes the scanned paths to $LIST, prints them
  bash "$GARI" scan "$1" | jq -r 'select(.event=="item") | .path' | sort | tee "$LIST"
}

age() { # make every file under $1 (and $1) old
  find "$1" -exec touch -h -d '60 days ago' {} +
}

assert_json_lines() {
  while IFS= read -r l; do echo "$l" | jq -e . >/dev/null || { echo "bad line: $l"; return 1; }; done <<<"$1"
}

# ---- caches ----------------------------------------------------------------

@test "caches: scan lists package caches and python caches, skips deps and .git" {
  mkdir -p "$HOME/.npm/_cacache" "$HOME/.cache/pip/http"
  head -c 5000 /dev/zero > "$HOME/.cache/pip/http/blob"
  mkdir -p "$GARI_ROOT/app/src/__pycache__" "$GARI_ROOT/app/.pytest_cache" \
           "$GARI_ROOT/app/.venv/lib/__pycache__" "$GARI_ROOT/app/.git/__pycache__" \
           "$GARI_ROOT/app/node_modules/x/.ruff_cache"
  run paths scan caches item
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$GARI_ROOT/app/.pytest_cache" "$GARI_ROOT/app/src/__pycache__" \
      "$HOME/.cache/pip" "$HOME/.npm/_cacache" | sort)" ]
}

@test "caches: clean removes exactly what scan listed and reports bytes" {
  mkdir -p "$HOME/.cache/pip" "$GARI_ROOT/a/__pycache__" "$GARI_ROOT/a/.venv/__pycache__"
  head -c 10000 /dev/zero > "$HOME/.cache/pip/f"
  scanned=$(scan_list caches)
  removed=$(paths clean caches removed)
  [ "$scanned" = "$removed" ]
  [ ! -e "$HOME/.cache/pip" ]
  [ ! -e "$GARI_ROOT/a/__pycache__" ]
  [ -d "$GARI_ROOT/a/.venv/__pycache__" ]
}

@test "caches: done event totals the item bytes" {
  mkdir -p "$HOME/.cache/pip"
  head -c 20000 /dev/urandom > "$HOME/.cache/pip/f"
  out=$(bash "$GARI" scan caches)
  assert_json_lines "$out"
  sum=$(echo "$out" | jq -s '[.[]|select(.event=="item")|.bytes]|add')
  done_bytes=$(echo "$out" | jq -s '.[]|select(.event=="done")|.bytes')
  [ "$sum" = "$done_bytes" ]
  [ "$sum" -ge 20000 ]
  [ "$(echo "$out" | jq -s '.[]|select(.event=="done")|.count')" = 1 ]
}

@test "caches: nothing to clean still emits done with zero" {
  rm -rf "$GARI_ROOT"
  run bash "$GARI" scan caches
  [ "$status" -eq 0 ]
  [ "$output" = '{"event":"done","category":"caches","bytes":0,"count":0}' ]
}

@test "paths with quotes and spaces stay valid JSON" {
  mkdir -p "$GARI_ROOT/we\"ird dir/__pycache__"
  out=$(bash "$GARI" scan caches)
  assert_json_lines "$out"
  [ "$(echo "$out" | jq -r 'select(.event=="item")|.path')" = "$GARI_ROOT/we\"ird dir/__pycache__" ]
}

# ---- stale-deps ------------------------------------------------------------

@test "stale-deps: only deps of projects untouched for 30 days" {
  mkdir -p "$GARI_ROOT/old/node_modules/a" "$GARI_ROOT/old/.venv/bin" "$GARI_ROOT/new/node_modules/a"
  echo x > "$GARI_ROOT/old/package.json"; echo x > "$GARI_ROOT/new/package.json"
  mkdir -p "$GARI_ROOT/old/node_modules/a/node_modules/b"
  age "$GARI_ROOT/old"
  # a fresh file inside node_modules must not make the project look alive
  echo y > "$GARI_ROOT/old/node_modules/a/fresh.js"
  run paths scan stale-deps item
  [ "$output" = "$(printf '%s\n' "$GARI_ROOT/old/.venv" "$GARI_ROOT/old/node_modules" | sort)" ]
}

@test "stale-deps: clean removes the stale deps and keeps project files" {
  mkdir -p "$GARI_ROOT/old/node_modules/a" "$GARI_ROOT/new/node_modules/a"
  echo x > "$GARI_ROOT/old/index.js"; echo x > "$GARI_ROOT/new/index.js"
  age "$GARI_ROOT/old"
  scanned=$(scan_list stale-deps)
  removed=$(paths clean stale-deps removed)
  [ "$scanned" = "$removed" ]
  [ ! -e "$GARI_ROOT/old/node_modules" ]
  [ -f "$GARI_ROOT/old/index.js" ]
  [ -d "$GARI_ROOT/new/node_modules" ]
}

@test "stale-deps: freshness is judged at the repo root, not a generated subfolder" {
  mkdir -p "$GARI_ROOT/mail/.react-email/node_modules/a"
  echo x > "$GARI_ROOT/mail/.react-email/package.json"
  git init -q "$GARI_ROOT/mail"
  age "$GARI_ROOT/mail"
  echo fresh > "$GARI_ROOT/mail/template.tsx"   # project is in active use
  run paths scan stale-deps item
  [ -z "$output" ]
  age "$GARI_ROOT/mail"
  run paths scan stale-deps item
  [ "$output" = "$GARI_ROOT/mail/.react-email/node_modules" ]
}

@test "stale-deps: GARI_STALE_DAYS changes the threshold" {
  mkdir -p "$GARI_ROOT/p/node_modules"; echo x > "$GARI_ROOT/p/a.js"
  find "$GARI_ROOT/p" -exec touch -d '10 days ago' {} +
  GARI_STALE_DAYS=30 run paths scan stale-deps item
  [ -z "$output" ]
  GARI_STALE_DAYS=5 run paths scan stale-deps item
  [ "$output" = "$GARI_ROOT/p/node_modules" ]
}

# ---- worktrees -------------------------------------------------------------

make_repo() { # creates $GARI_ROOT/repo with origin and origin/HEAD
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$GARI_ROOT/repo" 2>/dev/null
  cd "$GARI_ROOT/repo"
  echo base > f; git add f; git commit -qm base; git push -q origin main
  git remote set-head origin main
  echo '.env' > .gitignore; git add .gitignore; git commit -qm ignore; git push -q origin main
  WT="$HOME/.claude-worktrees/repo"
  mkdir -p "$WT"
}

add_wt() { # name -> worktree with one commit on its own branch, pushed under its name
  git -C "$GARI_ROOT/repo" worktree add -q "$WT/$1" -b "$1" main
  ( cd "$WT/$1" && echo "$1" > "$1.txt" && git add . && git commit -qm "$1" && git push -q -u origin "$1" 2>/dev/null )
}

land() { # merge branch into main on origin, refresh
  ( cd "$GARI_ROOT/repo" && git merge -q --no-ff "$1" -m "merge $1" && git push -q origin main )
}

@test "worktrees: only merged, pushed, clean .claude-worktrees are candidates" {
  make_repo
  add_wt landed; land landed
  add_wt open                                   # pushed, not merged
  add_wt dirty; land dirty; echo x > "$WT/dirty/untracked"
  add_wt ignored; land ignored; echo s > "$WT/ignored/.env"
  git -C "$GARI_ROOT/repo" worktree add -q "$WT/local" -b local main  # never pushed
  git -C "$GARI_ROOT/repo" worktree add -q "$GARI_ROOT/elsewhere" -b elsewhere main
  run paths scan worktrees item
  [ "$output" = "$WT/landed" ]
}

@test "worktrees: squash-landed branch counts as landed" {
  make_repo
  add_wt sq
  ( cd "$GARI_ROOT/repo" && git merge -q --squash sq && git commit -qm squash && git push -q origin main )
  run paths scan worktrees item
  [ "$output" = "$WT/sq" ]
}

@test "worktrees: clean removes the candidate, keeps its branch and the rest" {
  make_repo
  add_wt landed; land landed
  add_wt open
  scan_list worktrees >/dev/null
  removed=$(paths clean worktrees removed)
  [ "$removed" = "$WT/landed" ]
  [ ! -e "$WT/landed" ]
  [ -d "$WT/open" ]
  git -C "$GARI_ROOT/repo" rev-parse --verify -q landed >/dev/null
  ! git -C "$GARI_ROOT/repo" worktree list | grep -q "$WT/landed"
}

@test "worktrees: repo without origin/HEAD is skipped, not an error" {
  git init -q "$GARI_ROOT/bare-local"
  run bash "$GARI" scan worktrees
  [ "$status" -eq 0 ]
  [ "$output" = '{"event":"done","category":"worktrees","bytes":0,"count":0}' ]
}

# ---- docker ----------------------------------------------------------------

fake_docker() {
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/docker.calls"
case "$1" in
  info) exit 0 ;;
  system)
    case "$2" in
      df) printf 'Images\t1.5GB (40%%)\nContainers\t12.3kB (100%%)\nLocal Volumes\t9GB (100%%)\nBuild Cache\t0B\n' ;;
      prune) printf 'Deleted Images:\nx\n\nTotal reclaimed space: 2.25GB\n' ;;
    esac ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
}

@test "docker: scan reports reclaimable images, containers, build cache but not volumes" {
  fake_docker
  out=$(bash "$GARI" scan docker)
  assert_json_lines "$out"
  [ "$(echo "$out" | jq -r 'select(.event=="item")|"\(.path)=\(.bytes)"')" = "$(printf '%s\n' \
      'docker: Images=1500000000' 'docker: Containers=12300' 'docker: Build Cache=0')" ]
}

@test "docker: clean prunes all unused without --volumes and reports reclaimed space" {
  fake_docker
  scan_list docker >/dev/null
  out=$(bash "$GARI" clean docker "$LIST")
  grep -qx 'system prune -af' "$HOME/docker.calls"
  ! grep -q volumes "$HOME/docker.calls"
  [ "$(echo "$out" | jq -s '.[]|select(.event=="done")|.bytes')" = 2250000000 ]
}

@test "docker: not running logs a skip and still finishes" {
  run bash "$GARI" scan docker
  [ "$status" -eq 0 ]
  echo "$output" | jq -se 'any(.[]; .event=="log")' >/dev/null
  echo "$output" | grep -q '"event":"done","category":"docker","bytes":0'
}

@test "docker: clean with no docker item on the list prunes nothing" {
  fake_docker
  : > "$LIST"
  bash "$GARI" clean docker "$LIST" >/dev/null
  ! grep -q prune "$HOME/docker.calls"
}

# ---- clean only what the user saw --------------------------------------------

@test "clean refuses to run without the scanned list" {
  mkdir -p "$HOME/.cache/pip"
  run bash "$GARI" clean caches
  [ "$status" -eq 2 ]
  [ -d "$HOME/.cache/pip" ]
  run bash "$GARI" clean caches "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 2 ]
  [ -d "$HOME/.cache/pip" ]
}

@test "clean skips candidates that appeared after the scan" {
  mkdir -p "$GARI_ROOT/old/node_modules"; echo x > "$GARI_ROOT/old/a.js"
  age "$GARI_ROOT/old"
  scan_list stale-deps >/dev/null
  # a second project crosses the threshold between scan and clean
  mkdir -p "$GARI_ROOT/late/node_modules"; echo x > "$GARI_ROOT/late/a.js"
  age "$GARI_ROOT/late"
  removed=$(paths clean stale-deps removed)
  [ "$removed" = "$GARI_ROOT/old/node_modules" ]
  [ -d "$GARI_ROOT/late/node_modules" ]
}

@test "clean skips listed paths that no longer qualify" {
  mkdir -p "$GARI_ROOT/p/node_modules"; echo x > "$GARI_ROOT/p/a.js"
  age "$GARI_ROOT/p"
  scan_list stale-deps >/dev/null
  echo edit > "$GARI_ROOT/p/a.js"   # user resumed work on it
  removed=$(paths clean stale-deps removed)
  [ -z "$removed" ]
  [ -d "$GARI_ROOT/p/node_modules" ]
}

@test "stale-deps: a project find cannot fully read is never treated as stale" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  mkdir -p "$GARI_ROOT/locked/node_modules" "$GARI_ROOT/locked/build"
  echo x > "$GARI_ROOT/locked/a.js"
  age "$GARI_ROOT/locked"
  chmod 000 "$GARI_ROOT/locked/build"
  run paths scan stale-deps item
  chmod 755 "$GARI_ROOT/locked/build"
  [ -z "$output" ]
}

# ---- cli -------------------------------------------------------------------

@test "unknown category or command fails" {
  run bash "$GARI" scan nope
  [ "$status" -eq 2 ]
  run bash "$GARI" nuke caches
  [ "$status" -eq 2 ]
  run bash "$GARI"
  [ "$status" -eq 2 ]
}
