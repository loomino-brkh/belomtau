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
tracked_files=$(git ls-tree -r HEAD --name-only)

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

# Pull changes from remote
if ! git pull --ff-only; then
    # Restore stashed changes if pull fails
    git stash pop -q 2>/dev/null
    echo "Pull failed in: $REPO_DIR"
    exit 1
fi

# Restore ignored files from the temporary working directory
if [ -n "$ignored_files" ]; then
    while IFS= read -r file; do
        if [ -e ".git/tmp_workdir/$file" ]; then
            mkdir -p "$(dirname "$file")"
            cp -a ".git/tmp_workdir/$file" "$file"
        fi
    done <<< "$ignored_files"
fi

# Clean up temporary directory
rm -rf .git/tmp_workdir

# Try to restore stashed changes, ignore if stash was empty
git stash pop -q 2>/dev/null || true

# Final cleanup: Remove untracked files that aren't ignored
git clean -fdn | grep 'Would remove' | cut -c14- | while read -r file; do
    if ! echo "$tracked_files" | grep -q "^$file$" && \
       ! echo "$ignored_files" | grep -q "^$file$"; then
        rm -rf "$file"
    fi
done

echo "Successfully synced with remote in: $REPO_DIR"
