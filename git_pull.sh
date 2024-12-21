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
    git reset --hard @{u}
    git clean -fd
    if ! git pull --ff-only; then
        echo "Pull failed in: $REPO_DIR"
        exit 1
    fi
fi
