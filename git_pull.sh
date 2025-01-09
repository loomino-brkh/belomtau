#!/bin/bash

REPO_DIR="$1"

if [ -z "$REPO_DIR" ]; then
  echo "Usage: $0 <repository_directory>"
  exit 1
fi

cd "$REPO_DIR" || exit 1

# Fetch from remote silently
git fetch &>/dev/null

# Check if there are any changes to pull
if git diff --quiet HEAD @{u}; then
    echo "No changes detected in: $REPO_DIR"
    exit 0
fi

echo "Changes detected, syncing with remote in: $REPO_DIR"

# Stash any uncommitted changes to tracked files
git stash -q

# Save a list of files being tracked by git
# Get list of tracked files, handle potential errors
tracked_files=$(git ls-tree -r HEAD --name-only) || {
				echo "Error: Failed to get list of tracked files"
				exit 1
}

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

# Pull changes from remote
if ! git pull --ff-only; then
    # Restore stashed changes if pull fails
    git stash pop -q 2>/dev/null
    echo "Pull failed in: $REPO_DIR"
    exit 1
fi

# Restore ignored items from backup
if [ -d "$backup_dir" ]; then
    # Use cp -a to preserve attributes and copy directories recursively
    cp -a "$backup_dir"/* . 2>/dev/null || true
    
    # Clean up backup directory
    rm -rf "$backup_dir"
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
