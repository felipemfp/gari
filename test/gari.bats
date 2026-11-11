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
  # Only the fake: never Docker Desktop's docker.exe through WSL interop.
  export GARI_DOCKER=docker
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
    case "$2 $3" in
      "df -v") cat "$HOME/volumes" 2>/dev/null ;;
      df*) printf 'Images\t1.5GB (40%%)\nContainers\t12.3kB (100%%)\nLocal Volumes\t9GB (100%%)\nBuild Cache\t0B\n' ;;
      prune*) printf 'Deleted Images:\nx\n\nTotal reclaimed space: 2.25GB\n' ;;
    esac ;;
  volume) [ "$2" = rm ] && ! grep -qx "$3" "$HOME/busy" 2>/dev/null ;;
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

@test "docker: falls back to the next CLI when the first cannot reach a daemon, CRs stripped" {
  # WSL without Docker Desktop integration: no working `docker`, but docker.exe
  # via interop works and prints CRLF.
  fake_docker
  mv "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/docker.exe"
  printf '#!/bin/sh\nexec "%s" "$@" | sed "s/$/\\r/"\n' "$BATS_TEST_TMPDIR/bin/docker.exe" > "$BATS_TEST_TMPDIR/winexe"
  chmod +x "$BATS_TEST_TMPDIR/winexe"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/docker"; chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export GARI_DOCKER="docker
$BATS_TEST_TMPDIR/winexe"
  out=$(bash "$GARI" scan docker)
  assert_json_lines "$out"
  [ "$(echo "$out" | jq -r 'select(.event=="item" and .path=="docker: Images")|.bytes')" = 1500000000 ]
}

# ---- docker-volumes ---------------------------------------------------------

ANON1=$(printf 'a%.0s' {1..64})
ANON2=$(printf 'b%.0s' {1..64})
ANON3=$(printf 'c%.0s' {1..64})

fake_volumes() {
  fake_docker
  printf '%s\n' "$ANON1 0 1.5GB" "$ANON2 1 2GB" "pgdata 0 3GB" "$ANON3 0 52.05MB" > "$HOME/volumes"
}

@test "docker-volumes: only unreferenced anonymous volumes; named and in-use ones never" {
  fake_volumes
  run paths scan docker-volumes item
  [ "$output" = "$(printf 'docker volume: %s\n' "$ANON1" "$ANON3" | sort)" ]
}

@test "docker-volumes: clean removes listed ones by name with volume rm, never prune" {
  fake_volumes
  scan_list docker-volumes >/dev/null
  out=$(bash "$GARI" clean docker-volumes "$LIST")
  grep -qx "volume rm $ANON1" "$HOME/docker.calls"
  grep -qx "volume rm $ANON3" "$HOME/docker.calls"
  ! grep -q 'prune' "$HOME/docker.calls"
  ! grep -q 'pgdata' "$HOME/docker.calls"
  [ "$(echo "$out" | jq -s '.[]|select(.event=="done")|.bytes')" = 1552050000 ]
}

@test "docker-volumes: a volume put back in use after the scan is skipped and logged" {
  fake_volumes
  scan_list docker-volumes >/dev/null
  echo "$ANON1" > "$HOME/busy"   # docker refuses: a container started using it
  out=$(bash "$GARI" clean docker-volumes "$LIST")
  [ "$(echo "$out" | jq -r 'select(.event=="removed")|.path')" = "docker volume: $ANON3" ]
  echo "$out" | jq -se 'any(.[]; .event=="log" and (.message|test("refused")))' >/dev/null
}

@test "docker-volumes: a volume not on the scanned list is not removed" {
  fake_volumes
  printf 'docker volume: %s\n' "$ANON3" > "$LIST"
  bash "$GARI" clean docker-volumes "$LIST" >/dev/null
  ! grep -q "volume rm $ANON1" "$HOME/docker.calls"
}

# ---- poetry-envs ------------------------------------------------------------

ENVS() { echo "$HOME/.cache/pypoetry/virtualenvs"; }

poetry_hash_py() { # reference: poetry's generate_env_name hash
  python3 -c 'import base64,hashlib,os,sys; print(base64.urlsafe_b64encode(hashlib.sha256(os.path.realpath(sys.argv[1]).encode()).digest()).decode()[:8])' "$1"
}

mkenv() { # name project-dir-or-empty -> env dir; records the editable install like poetry
  local e="$(ENVS)/$1"
  mkdir -p "$e/lib/python3.12/site-packages/proj-0.1.dist-info"
  [ -n "$2" ] && printf '{"dir_info": {"editable": true}, "url": "file://%s"}' "$2" \
    > "$e/lib/python3.12/site-packages/proj-0.1.dist-info/direct_url.json"
  echo "$e"
}

@test "poetry-envs: hash matches poetry's own generate_env_name" {
  command -v python3 >/dev/null || skip "no python3"
  mkdir -p "$GARI_ROOT/my app"
  src=$(sed '/^# ---- main/,$d' "$GARI")
  got=$(eval "$src"; poetry_hash "$GARI_ROOT/my app")
  [ "$got" = "$(poetry_hash_py "$GARI_ROOT/my app")" ]
}

@test "poetry-envs: env of a deleted project is orphaned; live, unknown and unnamed ones are kept" {
  command -v python3 >/dev/null || skip "no python3"
  mkdir -p "$GARI_ROOT/live"; touch "$GARI_ROOT/live/pyproject.toml"
  live=$(mkenv "live-$(poetry_hash_py "$GARI_ROOT/live")-py3.12" "$GARI_ROOT/live")
  # its worktree was deleted: direct_url points nowhere
  gone=$(mkenv "gone-AAAAAAAA-py3.12" "$HOME/.claude-worktrees/repo/abc/projects/gone")
  # project outside the searched roots, still on disk: kept by its direct_url
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/proj"
  away=$(mkenv "away-BBBBBBBB-py3.12" "$BATS_TEST_TMPDIR/elsewhere/proj")
  # no record of its project (--no-root), even untouched for 60 days: kept,
  # a daily-used env writes nothing near its top level
  norec=$(mkenv "norec-DDDDDDDD-py3.12" ""); age "$norec"
  # not poetry's naming: never ours
  odd=$(mkenv "custom-env" "$HOME/nowhere"); age "$odd"
  run paths scan poetry-envs item
  [ "$output" = "$gone" ]
}

@test "poetry-envs: an env with one path dependency still on disk is kept" {
  e=$(mkenv "multi-EEEEEEEE-py3.12" "$HOME/gone/app")
  mkdir -p "$GARI_ROOT/libs/shared" "$e/lib/python3.12/site-packages/shared-0.1.dist-info"
  printf '{"url": "file://%s"}' "$GARI_ROOT/libs/shared" > "$e/lib/python3.12/site-packages/shared-0.1.dist-info/direct_url.json"
  run paths scan poetry-envs item
  [ -z "$output" ]
}

@test "poetry-envs: projects inside worktrees outside GARI_ROOT count as live" {
  command -v python3 >/dev/null || skip "no python3"
  make_repo
  add_wt feat
  # too deep for the shallow $HOME search; only found through `git worktree list`
  mkdir -p "$WT/feat/projects/svc"; touch "$WT/feat/projects/svc/pyproject.toml"
  # its install record points somewhere gone, so only the hash can keep it
  e=$(mkenv "svc-$(poetry_hash_py "$WT/feat/projects/svc")-py3.12" "$HOME/gone/svc")
  run paths scan poetry-envs item
  [ -z "$output" ]
}

@test "poetry-envs: clean removes the listed orphan only" {
  a=$(mkenv "a-AAAAAAAA-py3.12" "$HOME/gone/a")
  b=$(mkenv "b-BBBBBBBB-py3.12" "$HOME/gone/b")
  printf '%s\n' "$a" > "$LIST"
  removed=$(paths clean poetry-envs removed)
  [ "$removed" = "$a" ]
  [ ! -e "$a" ]
  [ -d "$b" ]
}

# ---- caches: tool caches and VS Code servers ---------------------------------

@test "caches: tool caches are listed when present" {
  mkdir -p "$HOME/.bun/install/cache" "$HOME/.cache/ms-playwright" "$HOME/.cache/pypoetry/artifacts" \
           "$HOME/.cache/pypoetry/virtualenvs/x"
  run paths scan caches item
  [ "$output" = "$(printf '%s\n' "$HOME/.bun/install/cache" "$HOME/.cache/ms-playwright" \
      "$HOME/.cache/pypoetry/artifacts" | sort)" ]
}

@test "caches: older VS Code server builds go, the newest stays" {
  b="$HOME/.vscode-server/bin"
  mkdir -p "$b/old1" "$b/old2" "$b/new"
  touch -d '30 days ago' "$b/old1"; touch -d '10 days ago' "$b/old2"; touch "$b/new"
  touch "$HOME/.vscode-server/bin/stray-file"
  run paths scan caches item
  [ "$output" = "$(printf '%s\n' "$b/old1" "$b/old2" | sort)" ]
}

@test "caches: an older VS Code build a running process uses is kept" {
  b="$HOME/.vscode-server/bin"
  mkdir -p "$b/old" "$b/new"
  touch -d '30 days ago' "$b/old"
  printf '#!/bin/sh\nsleep 30\n' > "$b/old/server.sh"; chmod +x "$b/old/server.sh"
  "$b/old/server.sh" & pid=$!
  run paths scan caches item
  kill "$pid" 2>/dev/null
  [ -z "$output" ]
}

# ---- report -----------------------------------------------------------------

@test "report: one JSON object per line, measurements present, exactly one done" {
  mkdir -p "$HOME/.cache/pip" "$HOME/.claude-worktrees/r/abc"
  head -c 10000 /dev/zero > "$HOME/.cache/pip/f"
  out=$(bash "$GARI" report)
  assert_json_lines "$out"
  [ "$(echo "$out" | jq -s '[.[]|select(.event=="done")]|length')" = 1 ]
  for sec in wsl-df wsl-home wsl-cache wsl-worktrees clean-caches poetry clean-stale-deps clean-worktrees; do
    echo "$out" | jq -se --arg s "$sec" 'any(.[]; .event=="stat" and .section==$s)' >/dev/null || { echo "missing $sec"; return 1; }
  done
  [ "$(echo "$out" | jq -r 'select(.section=="clean-caches")|.bytes')" -ge 10000 ]
}

@test "report: docker volumes split anonymous vs named, with names" {
  fake_volumes
  out=$(bash "$GARI" report)
  [ "$(echo "$out" | jq -r 'select(.section=="docker-volumes" and .label=="anonymous")|"\(.bytes) \(.data.count)"')" = "1552050000 2" ]
  [ "$(echo "$out" | jq -c 'select(.section=="docker-volumes" and .label=="named")|.data.names')" = '["pgdata"]' ]
}

@test "report: docker down is logged, not fatal" {
  out=$(bash "$GARI" report)
  echo "$out" | jq -se 'any(.[]; .event=="log" and (.message|test("docker")))' >/dev/null
  echo "$out" | tail -1 | jq -e '.event=="done" and .category=="report-wsl"' >/dev/null
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
