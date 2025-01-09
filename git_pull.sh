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


# Stash any uncommitted changes to tracked files
git stash -q

# Save a list of files being tracked by git
# Get list of tracked files, handle potential errors
tracked_files=$(git ls-tree -r HEAD --name-only) || {
  echo "Error: Failed to get list of tracked files"
  exit 1
}

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

# Set upstream branch if not configured
current_branch=$(git rev-parse --abbrev-ref HEAD)
if ! git rev-parse --verify @{u} >/dev/null 2>&1; then
  remote_name=$(git remote)
  if [ -z "$remote_name" ]; then
    echo "No remote configured for: $REPO_DIR"
				# Restore ignored files before exit
				if [ -d "$backup_dir" ]; then
						cp -a "$backup_dir"/* . 2>/dev/null || true
						rm -rf "$backup_dir"
    fi
    exit 1
  fi
  git branch --set-upstream-to="$remote_name/$current_branch" "$current_branch"
fi

# Pull changes from remote with error capture
pull_output=$(git pull --ff-only 2>&1)
pull_status=$?

# Always restore ignored items from backup first
if [ -d "$backup_dir" ]; then
		# Use cp -a to preserve attributes and copy directories recursively
		cp -a "$backup_dir"/* . 2>/dev/null || true
		# Clean up backup directory
		rm -rf "$backup_dir"
fi

if [ $pull_status -ne 0 ]; then
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
