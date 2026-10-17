#!/usr/bin/env bash
set -euo pipefail
session="$1"
dead=0
for ((attempt=0; attempt<${2:-100}; attempt++)); do
  state="$(tmux display-message -p -t "$session" '#{pane_dead}:#{pane_dead_status}:#{pane_dead_signal}')"
  IFS=: read -r dead status signal <<< "$state"
  if [[ "$dead" == 1 && -n "$signal" ]]; then
    echo "e2e-visual Neovim exited on signal $signal" >&2
    tmux capture-pane -p -t "$session" >&2
    exit 1
  fi
  if [[ "$dead" == 1 && "$status" =~ ^[0-9]+$ ]]; then
    if [[ "$status" != 0 ]]; then
      echo "e2e-visual failed with status $status" >&2
      tmux capture-pane -p -t "$session" >&2
    fi
    exit "$status"
  fi
  # A closed PTY can precede tmux's waitpid result; empty status is pending.
  sleep "${3:-0.05}"
done
if [[ "$dead" == 1 ]]; then
  echo "e2e-visual Neovim exit status did not become available" >&2
else
  echo "e2e-visual Neovim process did not exit" >&2
fi
tmux capture-pane -p -t "$session" >&2
exit 1
