#!/bin/bash

# Check if git command is available
if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed or not in PATH"
  exit 1
fi

REPO_DIR="$1"

if [ -z "$REPO_DIR" ]; then
  echo "Usage: $0 <repository_directory>"
  exit 1
fi

# Check if directory exists and is a git repository
if [ ! -d "$REPO_DIR" ]; then
  echo "Error: Directory does not exist: $REPO_DIR"
  exit 1
fi

cd "$REPO_DIR" || {
  echo "Error: Failed to change to directory: $REPO_DIR"
  exit 1
}

# Verify it's a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Error: Not a git repository: $REPO_DIR"
  exit 1
fi

# Get remote name first
remote_name=$(git remote)
if [ -z "$remote_name" ]; then
  echo "No remote configured for: $REPO_DIR"
  exit 1
fi

# Get current branch name, default to master/main if no commits exist
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "master")

# Fetch from remote silently
git fetch &>/dev/null

# Check if we have any commits
has_commits=false
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  has_commits=true
fi

# Set upstream branch if not configured
if ! git rev-parse --verify @{u} >/dev/null 2>&1; then
  git branch --set-upstream-to="$remote_name/$current_branch" "$current_branch" || {
    echo "Failed to set upstream branch. Please check remote branch exists."
    exit 1
  }
fi

# For repositories with commits, check if there are changes to pull
if [ "$has_commits" = true ]; then
  if git diff --quiet HEAD @{u}; then
    echo "No changes detected in: $REPO_DIR"
    exit 0
  fi
else
  echo "No commits yet, pulling initial content from remote"
fi

echo "Changes detected, syncing with remote in: $REPO_DIR"

# Stash any uncommitted changes to tracked files
git stash -q

# Save a list of files being tracked by git
tracked_files=""
if [ "$has_commits" = true ]; then
  tracked_files=$(git ls-tree -r HEAD --name-only)
fi

# Get a list of files and directories that are ignored by .gitignore
# Use -z to handle filenames with spaces and special characters
ignored_items=$(git status --ignored --porcelain -z | grep -z '^!!' | cut -c4- | tr '\0' '\n')

# Create a temporary directory for backup
backup_dir=".git/backup_ignored"
rm -rf "$backup_dir"
mkdir -p "$backup_dir"

# Backup ignored items with their directory structure
if [ -n "$ignored_items" ]; then
  while IFS= read -r item; do
    if [ -e "$item" ]; then
      # Create parent directories in backup
      parent_dir="$backup_dir/$(dirname "$item")"
      mkdir -p "$parent_dir"
      # Copy the item (file or directory) with its attributes
      cp -a "$item" "$parent_dir/"
    fi
  done <<< "$ignored_items"
fi

# Clean working directory, excluding ignored files
git clean -fd

# Pull changes from remote with auto conflict resolution favoring remote changes
pull_output=$(git pull --strategy=recursive --strategy-option=theirs "$remote_name" "$current_branch" 2>&1)
pull_status=$?

# Always restore ignored items from backup first
if [ -d "$backup_dir" ]; then
  # Use cp -a to preserve attributes and copy directories recursively
  cp -a "$backup_dir"/* . 2>/dev/null || true
  # Clean up backup directory
  rm -rf "$backup_dir"
fi

if [ $pull_status -ne 0 ]; then
  # Attempt to abort any failed merge
  git merge --abort &>/dev/null || true
  # Restore stashed changes if pull fails
  git stash pop -q 2>/dev/null
  echo "Pull failed in: $REPO_DIR"
  echo "Error: $pull_output"
  exit 1
fi

# Try to restore stashed changes, ignore if stash was empty
git stash pop -q 2>/dev/null || true

# Final cleanup: Remove untracked files that aren't ignored or tracked
git status --untracked-files=normal --porcelain | grep '^??' | cut -c4- | while IFS= read -r item; do
  # Check if the item is tracked
  if ! echo "$tracked_files" | grep -Fxq "$item"; then
    # Check if the item is ignored by git
    if ! git check-ignore -q "$item"; then
      rm -rf "$item"
    fi
  fi
done

echo "Successfully synced with remote in: $REPO_DIR"
