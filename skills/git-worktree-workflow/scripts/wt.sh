#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
wt.sh - safe git worktree helper

Usage:
  wt.sh create --branch <name> [--base <ref>] [--dir-mode auto|sibling|inside]
  wt.sh destroy --branch <name> [--dry-run] [--force]

Directory modes:
  auto    Prefer sibling: ../.worktrees/<repo>/<branch>, fallback to inside: <repo>/.worktrees/<branch>
  sibling Force sibling: ../.worktrees/<repo>/<branch>
  inside  Force inside:  <repo>/.worktrees/<branch>

Notes:
  - 'create' will:
      * validate branch name using 'git check-ref-format'
      * refuse if branch is already checked out in another worktree
      * create a new branch from --base if the branch doesn't exist
  - 'destroy' will:
      * locate the worktree path for the given branch
      * refuse if the branch is not attached to a worktree
      * run 'git worktree remove' and 'git worktree prune'
EOF
}

fail() {
  echo "[wt] ERROR: $*" >&2
  exit 1
}

info() {
  echo "[wt] $*" >&2
}

require_git_repo() {
  git rev-parse --show-toplevel >/dev/null 2>&1 || fail "Not inside a git repository"
}

repo_root() {
  git rev-parse --show-toplevel
}

repo_name() {
  basename "$(repo_root)"
}

main_branch_guess() {
  if git show-ref --verify --quiet refs/heads/main; then
    echo "main"
  elif git show-ref --verify --quiet refs/heads/master; then
    echo "master"
  else
    echo "main"
  fi
}

check_branch_name() {
  local b="$1"
  git check-ref-format --branch "$b" >/dev/null 2>&1 || fail "Invalid branch name: $b"
}

branch_exists() {
  local b="$1"
  git show-ref --verify --quiet "refs/heads/$b"
}

# Output: "<worktree_path>\t<branch_name>" pairs
list_worktrees() {
  git worktree list --porcelain | awk '
    $1=="worktree" {wt=$2}
    $1=="branch" {br=$2; sub("refs/heads/","",br); print wt"\t"br}
  '
}

branch_in_other_worktree() {
  local b="$1"
  local count
  count=$(list_worktrees | awk -v b="$b" '$2==b {c++} END{print c+0}')
  [ "$count" -gt 0 ]
}

worktree_path_for_branch() {
  local b="$1"
  local path
  path=$(list_worktrees | awk -v b="$b" '$2==b {print $1; exit 0}')
  if [ -z "${path}" ]; then
    return 1
  fi
  echo "$path"
}

ensure_empty_or_missing_dir() {
  local p="$1"
  if [ -e "$p" ]; then
    if [ -d "$p" ] && [ -z "$(ls -A "$p" 2>/dev/null || true)" ]; then
      return 0
    fi
    fail "Target path exists and is not an empty directory: $p"
  fi
}

select_base_dir() {
  local mode="$1"
  local root parent sib inside
  root="$(repo_root)"
  parent="$(cd "$(dirname "$root")" && pwd)"
  sib="$parent/.worktrees/$(repo_name)"
  inside="$root/.worktrees"

  case "$mode" in
    auto)
      if mkdir -p "$sib" 2>/dev/null; then
        echo "$sib"
      else
        mkdir -p "$inside"
        echo "$inside"
      fi
      ;;
    sibling)
      mkdir -p "$sib"
      echo "$sib"
      ;;
    inside)
      mkdir -p "$inside"
      echo "$inside"
      ;;
    *)
      fail "Unknown --dir-mode: $mode"
      ;;
  esac
}

cmd_create() {
  local branch=""
  local base=""
  local dir_mode="auto"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)
        branch="$2"; shift 2;;
      --base)
        base="$2"; shift 2;;
      --dir-mode)
        dir_mode="$2"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        fail "Unknown argument: $1";;
    esac
  done

  [ -n "$branch" ] || fail "--branch is required"
  check_branch_name "$branch"

  if branch_in_other_worktree "$branch"; then
    fail "Branch is already checked out in a worktree: $branch"
  fi

  local base_dir target
  base_dir="$(select_base_dir "$dir_mode")"
  target="$base_dir/$branch"
  ensure_empty_or_missing_dir "$target"

  if branch_exists "$branch"; then
    info "Creating worktree for existing branch '$branch' at: $target"
    git worktree add "$target" "$branch"
  else
    if [ -z "$base" ]; then
      local mb
      mb="$(main_branch_guess)"
      if git show-ref --verify --quiet "refs/remotes/origin/$mb"; then
        base="origin/$mb"
      else
        base="HEAD"
      fi
    fi
    info "Creating worktree with new branch '$branch' from '$base' at: $target"
    git worktree add -b "$branch" "$target" "$base"
  fi

  info "Done. Open: $target"
  printf '%s\n' "$target"
}

cmd_destroy() {
  local branch=""
  local force="false"
  local dry_run="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch)
        branch="$2"; shift 2;;
      --force)
        force="true"; shift 1;;
      --dry-run)
        dry_run="true"; shift 1;;
      -h|--help)
        usage; exit 0;;
      *)
        fail "Unknown argument: $1";;
    esac
  done

  [ -n "$branch" ] || fail "--branch is required"
  check_branch_name "$branch"

  local path
  if ! path="$(worktree_path_for_branch "$branch")"; then
    fail "No worktree found for branch: $branch"
  fi

  local root_abs path_abs
  root_abs="$(cd "$(repo_root)" && pwd)"
  path_abs="$(cd "$path" && pwd)"

  if [ "$path_abs" = "$root_abs" ]; then
    fail "Refusing to remove the main worktree (repo root): $path_abs"
  fi

  info "Target worktree for branch '$branch': $path_abs"

  if [ "$dry_run" = "true" ]; then
    printf '%s\n' "$path_abs"
    return 0
  fi

  info "Removing worktree for branch '$branch' at: $path_abs"

  if [ "$force" = "true" ]; then
    git worktree remove --force "$path_abs"
  else
    git worktree remove "$path_abs"
  fi

  git worktree prune

  info "Remaining worktrees:"
  git worktree list
}

main() {
  require_git_repo

  if [ "$#" -lt 1 ]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift
  case "$cmd" in
    create) cmd_create "$@";;
    destroy) cmd_destroy "$@";;
    -h|--help|help) usage; exit 0;;
    *) fail "Unknown command: $cmd";;
  esac
}

main "$@"
