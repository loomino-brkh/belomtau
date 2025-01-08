#!/bin/bash

REPO_DIR="$1"

if [ -z "$REPO_DIR" ]; then
  echo "Usage: $0 <repository_directory>"
  exit 1
fi

cd "$REPO_DIR" || exit 1

# Fetch silently
git fetch &>/dev/null

# Check if there are any changes to pull
if git diff --quiet HEAD @{u}; then
    exit 0
else
    echo "Changes detected, pulling updates in: $REPO_DIR"
    # Stash any uncommitted changes to tracked files
    git stash -q
    
    # Pull changes from remote
    if ! git pull --ff-only; then
        # Restore stashed changes if pull fails
        git stash pop -q 2>/dev/null
        echo "Pull failed in: $REPO_DIR"
        exit 1
    fi
    
    # Try to restore stashed changes, ignore if stash was empty
    git stash pop -q 2>/dev/null || true
fi
