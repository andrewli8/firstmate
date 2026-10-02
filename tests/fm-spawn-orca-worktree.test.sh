#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The matching relaunch-side carve-out at the `[ "$RELAUNCH" -eq 1 ] &&
# [ "$BACKEND" = orca ]` branch is guarded by an earlier, unconditional gate:
# fm_control_backend_state_verified (bin/fm-control-lib.sh) only recognizes
# tmux and herdr as having a recovery-grade agent-state classifier, so any
# `--relaunch` on backend=orca is refused before that branch can ever run.
# The second test below pins that refusal so a future change that starts
# routing orca through the classifier does not silently reach the untested
# branch without also covering it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal send")
    if [ -n "${FM_TEST_ORCA_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != --text ] || printf '%s\n' "$a" >> "$FM_TEST_ORCA_LOG"
        prev=$a
      done
    fi
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run() {
  local case_dir home proj wt id=orca-relaunch-a2 out status
  case_dir="$TMP_ROOT/relaunch"
  home="$case_dir/home"
  proj="$case_dir/proj"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a relaunch attempt against a recorded Orca task.

## Firstmate spec
Confirm the relaunch is refused before any worktree re-entry logic runs.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "backend=orca"
    echo "orca_worktree_id=wt-1::$wt"
    echo "terminal=term-1"
  } > "$home/state/$id.meta"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?

  expect_code 1 "$status" "a relaunch against a recorded Orca task should refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" \
    "the refusal should name the missing classifier, proving relaunch never reaches the worktree carve-out"
  pass "a relaunch against an Orca-backed task is refused before the RELAUNCH+orca worktree carve-out could run"
}

# Source values are synthetic and deliberately include shell syntax and trailing
# newlines. Removing the source overlay, ambient clearing, or quoting breaks
# these executions of the real staged spawn command.
test_orca_launch_uses_controlled_tmux_environment() {
  local setting case_dir home id fb out status staged staged_content result expected value pane_shell failbin
  for setting in absent enabled empty unavailable malformed nonregular missing; do
    id="orca-env-$setting"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'manual\n' > "$home/config/backlog-backend"
    printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
    if [ "$setting" = malformed ]; then printf 'wrong:selector\n' > "$home/config/launch-env-tmux-session"; fi
    if [ "$setting" = nonregular ]; then rm "$home/config/launch-env-tmux-session"; mkdir "$home/config/launch-env-tmux-session"; fi
    case "$setting" in
      enabled|missing) printf 'GH_TOKEN\nGH_CONFIG_DIR\nGIT_CONFIG_COUNT\nGIT_CONFIG_KEY_0\nGIT_CONFIG_VALUE_0\nGIT_CONFIG_KEY_1\nGIT_CONFIG_VALUE_1\nFM_TEST_NOT_SET\n' > "$home/config/launch-env-allowlist" ;;
      empty) : > "$home/config/launch-env-allowlist" ;;
      absent) ;;
      *) printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist" ;;
    esac
    [ "$setting" != missing ] || printf 'FM_TEST_ABSENT\n' >> "$home/config/launch-env-allowlist"
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify the controlled Orca environment source.

## Firstmate spec
Execute read-only environment checks.
EOF
    cat > "$case_dir/probe.sh" <<'EOF'
#!/bin/sh
launch_file=$(cat "$1")
[ ! -e "$launch_file" ] || { echo 'launch file still contains credentials when the worker starts' >&2; exit 1; }
printf '%s\n' "${GH_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" "${DATABASE_URL-unset}" "${FM_TEST_NOT_SET-unset}" "${FM_TEST_PERSONAL-unset}"
git config --get-all credential.helper || :
printf 'hooksPath=%s\n' "$(git config --get core.hooksPath || :)"
EOF
    value="synthetic-' \$(touch $case_dir/injected) \`false\`"$'\nline\n\n'
    VALUE="$value" python3 - "$case_dir/source.json" <<'PY'
import json,os,sys
with open(sys.argv[1], 'w') as f:
 json.dump({'GH_TOKEN':os.environ['VALUE'], 'GH_CONFIG_DIR':'scoped-gh', 'DATABASE_URL':'readonly-db', 'GIT_CONFIG_COUNT':'2', 'GIT_CONFIG_KEY_0':'credential.helper', 'GIT_CONFIG_VALUE_0':'', 'GIT_CONFIG_KEY_1':'credential.helper', 'GIT_CONFIG_VALUE_1':'!gh auth git-credential', 'FM_TEST_NOT_SET':None}, f)
PY
    fb=$(make_orca_fakebin "$case_dir")
    cat > "$fb/tmux" <<'EOF'
#!/usr/bin/env python3
import json,os,sys
if os.environ.get('FM_TEST_SOURCE_UNAVAILABLE') == '1': sys.exit(1)
if sys.argv[1:5] != ['-u','show-environment','-t','=scoped-source']: sys.exit(2)
with open(os.environ['FM_TEST_ORCA_DIR']+'/source.json') as f: data=json.load(f)
names=[sys.argv[5]] if len(sys.argv)>5 else data
for name in names:
 if name not in data: sys.exit(1)
 value=data[name]
 print('-'+name if value is None else name+'='+value)
EOF
    chmod +x "$fb/tmux"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
      FM_TEST_SOURCE_UNAVAILABLE="$([ "$setting" = unavailable ] && echo 1 || echo 0)" \
      PATH="$fb:$PATH" "$SPAWN" "$id" "$case_dir/project" \
      --mode direct-PR --yolo off --backend orca --harness "/bin/sh '$case_dir/probe.sh' '$case_dir/stage-path'" 2>&1)
    status=$?
    if [ "$setting" = absent ] || [ "$setting" = unavailable ] || [ "$setting" = malformed ] || [ "$setting" = nonregular ] || [ "$setting" = missing ]; then
      expect_code 1 "$status" "unavailable source must refuse: $out"
      [ ! -d "$case_dir/orca-worktrees" ] || fail "source refusal allocated a worktree"
      [ ! -f "$home/state/$id.meta" ] || fail "source refusal published metadata"
      pass "Orca refuses source=$setting before allocating resources"
      continue
    fi
    expect_code 0 "$status" "controlled-source spawn should succeed: $out"
    staged=$(sed -n "s/^\. '\([^']*\)'$/\1/p" "$case_dir/terminal.log" | tail -1)
    [ -f "$staged" ] || fail "Orca did not receive the staged launch path"
    [ "$(stat -f '%Lp' "$staged" 2>/dev/null || stat -c '%a' "$staged")" = 600 ] || fail "credential launch file is not private"
    [ "$(stat -f '%Lp' "$(dirname "$staged")" 2>/dev/null || stat -c '%a' "$(dirname "$staged")")" = 700 ] || fail "credential launch directory is not private"
    assert_not_contains "$(cat "$case_dir/terminal.log")" synthetic "source values leaked into terminal input"
    staged_content=$(cat "$staged")
    printf '%s\n' "$staged" > "$case_dir/stage-path"
    failbin=$(fm_fakebin "$case_dir/delete-refusal")
    printf '#!/bin/sh\nexit 1\n' > "$failbin/rm"
    chmod +x "$failbin/rm"
    case "$setting" in
      enabled) expected="$value"$'\nscoped-gh\nunset\nunset\nunset\n\n!gh auth git-credential' ;;
      empty) expected=$'unset\nunset\nunset\nunset\nunset' ;;
    esac
    # The strip-hook entry must also survive the env -i boundary.
    expected="$expected"$'\n'"hooksPath=$(cd "$home/state" && pwd -P)/$id.git-hooks"
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      (umask 077; printf '%s\n' "$staged_content" > "$staged")
      # shellcheck disable=SC2016 # The child pane expands the source path and its failure status.
      result=$(env -i HOME="$case_dir/user-home" PATH="$failbin:$PATH" TERM=xterm \
        "$pane_shell" -i -c '. "$1"; fm_status=$?; [ "$fm_status" -ne 0 ] || exit 2; printf "\nSHELL-STILL-ALIVE\n"' _ "$staged" 2>&1)
      expect_code 0 "$?" "failed deletion must preserve the interactive $pane_shell pane"
      assert_contains "$result" 'cannot remove private launch file' "deletion failure must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "deletion refusal killed the interactive $pane_shell pane"
      [ -f "$staged" ] || fail "failed deletion unexpectedly removed the private launch file"
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        GH_TOKEN=personal-token GH_CONFIG_DIR=personal-gh FM_TEST_PERSONAL=personal-value \
        FM_TEST_NOT_SET=personal-value GIT_CONFIG_NOSYSTEM=0 \
        "$pane_shell" -c ". '$staged'") || fail "controlled-source launch failed in $pane_shell"
      [ "$result" = "$expected" ] || fail "Orca source/allowlist=$setting lost isolation or values in $pane_shell"
      [ ! -e "$case_dir/injected" ] || fail "source value executed shell syntax"
      [ ! -e "$staged" ] || fail "secret-bearing launch file survived sourcing in $pane_shell"
    done
    pass "Orca source/allowlist=$setting preserves controlled values, clears ambient credentials and keeps values off terminal input"
  done
}

# The real tmux client sanitizes control characters without UTF-8 mode. A
# private socket and synthetic environment catch corruption the stub cannot.
test_orca_source_preserves_values_without_utf8_locale() {
  local real_tmux case_dir
  real_tmux=$(command -v tmux) || fail "tmux is required for the Orca source locale regression"
  case_dir=$(TMPDIR=/tmp fm_test_tmproot oenv)
  if ! python3 - "$real_tmux" "$case_dir" "$ROOT/bin/backends/orca.sh" <<'PY'
import os, pathlib, shlex, shutil, subprocess, sys
tmux, directory, adapter = sys.argv[1:]
root = pathlib.Path(directory)
socket = str(root / 'tmux.sock')
env = {'PATH': os.environ['PATH'], 'HOME': directory, 'TERM': 'xterm'}
value = "synthetic-' $(false) `false`\nFM_TEST_PHANTOM=evil-é\n\n"
def call(args, environment=env):
    return subprocess.run(args, env=environment, capture_output=True, text=True,
                          check=True, timeout=10).stdout
try:
    call([tmux, '-S', socket, '-f', '/dev/null', 'new-session', '-d',
          '-s', 'scoped-source', 'sleep 60'], dict(env, SSH_AUTH_SOCK='/tmp/fm-test-personal-agent'))
    call([tmux, '-S', socket, 'set-environment', '-t', '=scoped-source', 'GH_TOKEN', value])
    call([tmux, '-S', socket, 'set-environment', '-r', '-t', '=scoped-source', 'FM_TEST_NOT_SET'])
    call([tmux, '-S', socket, 'set-environment', '-g', 'FM_TEST_ABSENT', 'personal-global'])
    if call([tmux, '-u', '-S', socket, 'show-environment', '-t', '=scoped-source', 'SSH_AUTH_SOCK']) != 'SSH_AUTH_SOCK=/tmp/fm-test-personal-agent\n':
        raise AssertionError('real tmux did not automatically populate the synthetic personal agent')
    fakebin = root / 'bin'
    fakebin.mkdir()
    wrapper = fakebin / 'tmux'
    wrapper.write_text('#!/bin/sh\nexec '+shlex.quote(tmux)+' -S '+shlex.quote(socket)+' "$@"\n')
    wrapper.chmod(0o755)
    for locale in ['absent', 'C']:
        source_env = dict(env, PATH=str(fakebin)+os.pathsep+env['PATH'])
        if locale == 'C':
            source_env.update(LANG='C', LC_ALL='C', LC_CTYPE='C')
        for names in ['GH_TOKEN', 'GH_TOKEN\nFM_TEST_NOT_SET']:
            assignments = call(['bash', '-c', '. "$1"; fm_backend_orca_launch_env_args scoped-source 1 "$2"',
                                '_', adapter, names], source_env)
            for shell in ['sh', 'bash', 'zsh']:
                if shell == 'zsh' and not shutil.which(shell):
                    continue
                observed = call([shell, '-c', 'export '+assignments+'; test "${SSH_AUTH_SOCK-unset}" = unset && test "${FM_TEST_NOT_SET-unset}" = unset && printf %s "$GH_TOKEN"'], env)
                if observed != value:
                    raise AssertionError('tmux source corrupted the synthetic value: locale='+locale+', shell='+shell)
        for names in ['FM_TEST_ABSENT', 'FM_TEST_PHANTOM']:
            result = subprocess.run(['bash', '-c', '. "$1"; fm_backend_orca_launch_env_args scoped-source 1 "$2"',
                                     '_', adapter, names], env=source_env, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                raise AssertionError('missing session-local name was accepted: '+names)
finally:
    subprocess.run([tmux, '-S', socket, 'kill-server'], env=env,
                   capture_output=True, timeout=10, check=False)
PY
  then fail "real-tmux source must preserve exact values and refuse missing names"; fi
  pass "real tmux preserves absent/C locale values, rejects missing/phantom names and excludes the automatic SSH agent"
}

test_orca_source_preserves_values_without_utf8_locale
test_orca_launch_uses_controlled_tmux_environment
test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_is_refused_before_the_worktree_carveout_could_run

echo "# all fm-spawn-orca-worktree tests passed"
