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

# Get a list of files that are ignored by .gitignore
ignored_files=$(git status --ignored --porcelain | grep '^!!' | cut -c4-)

# Create a temporary index to store current tracked files state
git checkout-index -a --prefix=.git/tmp_workdir/

# Clean working directory, but keep ignored files
git clean -fdx

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
