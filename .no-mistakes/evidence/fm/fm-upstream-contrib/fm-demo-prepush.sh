#!/usr/bin/env bash
# Usage: fm-demo-prepush.sh <worktree> ; demo of inherited credential.helper reaching a repo pre-push hook
set -u
W=$1; T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
cd "$T"
git -C "$W" show 8690c411:bin/fm-git-strip-ai-trailers.sh > base-strip.sh; chmod +x base-strip.sh
git init -q --bare remote.git; git init -q repo
git -C repo config user.email t@e.x; git -C repo config user.name T; git -C repo remote add origin "$T/remote.git"
cat > repo/.git/hooks/pre-push <<'SH'
#!/bin/sh
# stand-in for git-lfs pre-push: which credential helpers would `git credential fill` consult?
echo "  [repo pre-push] credential.helper entries: $(git config --get-all credential.helper | sed 's/^$/<empty reset>/' | paste -sd, -)"
echo "  [repo pre-push] core.hooksPath seen: '$(git config --get core.hooksPath)'"
SH
chmod +x repo/.git/hooks/pre-push
inherit=(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= GIT_CONFIG_KEY_1=credential.helper 'GIT_CONFIG_VALUE_1=!gh auth git-credential')
worker='cd "$T/repo"; echo "  [worker] credential.helper: $(git config --get-all credential.helper | sed "s/^\$/<empty reset>/" | paste -sd, -)"; echo "$RANDOM$$" >f; git add f; git commit -qm "fix: demo" --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>"; git push -q -f origin HEAD:refs/heads/demo; echo "  [worker] commit body: $(git log -1 --format=%B | paste -sd"|" -)"'
export T
echo "Pane inherits: ${inherit[*]}"
echo "(system git config also has credential.helper=$(git config --system --get credential.helper 2>/dev/null || echo none))"
echo
echo "=== BASE 8690c411: launch prefix 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath ...' ==="
./base-strip.sh install "$T/hooks-base" "$T/repo" || echo "base install failed"
env HOME="$T" ZDOTDIR="$T" ENV= "${inherit[@]}" /bin/sh -c "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='$T/hooks-base'; $worker"
echo
echo "=== HEAD 2349ac47: launch prefix '<strip> env-file <hooks> <file> && . <file> || return 1 2>/dev/null || exit 1;' ==="
"$W/bin/fm-git-strip-ai-trailers.sh" install "$T/hooks-head" "$T/repo" || echo "head install failed"
for sh in /bin/sh /opt/homebrew/bin/bash /bin/zsh; do
  echo "-- pane shell $sh"
  env HOME="$T" ZDOTDIR="$T" ENV= "${inherit[@]}" "$sh" -c "'$W/bin/fm-git-strip-ai-trailers.sh' env-file '$T/hooks-head' '$T/envfile' && . '$T/envfile' || exit 1; echo \"  [env-file] \$(cat '$T/envfile')\"; $worker"
done
echo
echo "=== HEAD: invalid inherited GIT_CONFIG_COUNT stops the launch before the worker runs ==="
env GIT_CONFIG_COUNT=bad /bin/sh -c "'$W/bin/fm-git-strip-ai-trailers.sh' env-file '$T/hooks-head' '$T/envfile2' && . '$T/envfile2' || { echo \"  launch stopped, rc=\$?\"; exit 0; }; echo '  WORKER RAN (unexpected)'" 2>&1
