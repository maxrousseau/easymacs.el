#!/usr/bin/env zsh
# wt.sh — worktree-per-feature helper for Ghostty + tmux + Emacs + Claude Code.
#
# Source from ~/.zshrc:
#     source ~/code/easymacs/wt.sh
#
# Requires: git, tmux, gum (`brew install gum`).
# Uses zsh-specific syntax (`print -r`, `[[`, parameter substitution).

# Sanitize a name for tmux session / branch use; tmux forbids "." and ":".
_wt_sanitize() { print -r -- "${1//[^A-Za-z0-9_-]/-}"; }

# Add `.worktrees/` to the repo's local excludes so rg/fd don't descend
# into sibling worktrees. Idempotent per repo.
_wt_exclude() {
  local root
  root=$(git rev-parse --show-toplevel) || return 1
  local ex="$root/.git/info/exclude"
  grep -qxF '.worktrees/' "$ex" 2>/dev/null || print -- '.worktrees/' >> "$ex"
}

# wt [name] — create worktree at <repo>/.worktrees/<name>, start tmux
# session with edit/claude/term windows, attach.
wt() {
  local root
  root=$(git rev-parse --show-toplevel) \
    || { print -u2 "wt: not in a git repo"; return 1; }
  local repo
  repo=$(basename "$root")

  local name="$1"
  if [[ -z "$name" ]]; then
    name=$(gum input --prompt "feature name › " --placeholder "my-feature") \
      || return 1
  fi
  [[ -z "$name" ]] && { print -u2 "wt: aborted"; return 1; }

  local safe
  safe=$(_wt_sanitize "$name")
  local wt_path="$root/.worktrees/$safe"

  gum style --border rounded --padding "0 1" --margin "1 0" \
    "$(printf 'repo    %s\nbranch  %s (new)\npath    %s\ntmux    edit · claude · term' \
       "$repo" "$safe" ".worktrees/$safe")"
  gum confirm "proceed?" || { print "aborted"; return 1; }

  _wt_exclude

  if [[ ! -d "$wt_path" ]]; then
    gum spin --title "creating worktree..." -- \
      git -C "$root" worktree add "$wt_path" -b "$safe" || return 1
  fi

  if ! tmux has-session -t="$safe" 2>/dev/null; then
    # Window order: claude (0, default on attach), edit (1), term (2).
    # Plain default shells — the welcome banner is injected via send-keys
    # below rather than as new-session's shell-command, which breaks
    # tmux arg parsing when it contains unicode/quotes/semicolons.
    tmux new-session -d -s "$safe" -c "$wt_path" -n claude 'claude'  || return 1
    tmux new-window  -t "$safe:"   -c "$wt_path" -n edit 'emacs -nw' || return 1
    tmux new-window  -t "$safe:"   -c "$wt_path" -n term             || return 1
    tmux select-window -t "$safe:claude"                             || return 1

    # Type the welcome banner into the term window's shell.  Visible in
    # scrollback if the user switches to term later.
    tmux send-keys -t "$safe:term" \
      "clear && gum style --border rounded --padding '0 1' --foreground 42 '✓ worktree ready' 'branch    $safe' 'path      .worktrees/$safe' 'windows: C-z 0 claude · C-z 1 edit · C-z 2 term'" Enter
  fi

  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$safe"
  else
    tmux attach -t "$safe"
  fi
}
