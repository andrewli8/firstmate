#!/usr/bin/env bash
# Manual check: an inherited LAUNCH_FILE must survive an Orca spawn abort
# after the tmux environment source is enabled (review round 2 fix).
set -u
WT=$1
. "$WT/tests/fixtures.sh"
eval "$(sed -n '/^make_orca_fakebin()/,/^}/p' "$WT/tests/fm-spawn-orca-worktree.test.sh")"
T=$(mktemp -d /tmp/fm-inherit.XXXXXX)
id=orca-inherit; home=$T/home
mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
touch "$home/state/.last-watcher-beat"
printf 'manual\n' > "$home/config/backlog-backend"
printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
fm_git_init_commit "$T/project" >/dev/null
printf '# Task\n## Captain'"'"'s intent\nx\n\n## Firstmate spec\ny\n' > "$home/data/$id/brief.md"
fb=$(make_orca_fakebin "$T")
printf '#!/bin/sh\ncase "$*" in *GH_TOKEN*) echo GH_TOKEN=scoped;; *) echo GH_TOKEN=scoped;; esac\n' > "$fb/tmux"; chmod +x "$fb/tmux"
victim=$T/caller-owned-file; echo keep > "$victim"
sleep 120 & holder=$!
mkdir "$home/state/.spawn-$id.lock"; echo $holder > "$home/state/.spawn-$id.lock/pid"
out=$(LAUNCH_FILE="$victim" FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$T/user-home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$T" PATH="$fb:$PATH" \
  "$WT/bin/fm-spawn.sh" "$id" "$T/project" --mode direct-PR --yolo off --backend orca 2>&1)
echo "spawn exit=$? output: $out"
kill $holder 2>/dev/null
if [ -f "$victim" ]; then echo "PASS: inherited LAUNCH_FILE $victim survived the abort"; else echo "FAIL: inherited LAUNCH_FILE was deleted"; exit 1; fi
rm -rf "$T"
