#!/bin/bash

REPO_DIR="$1"

if [ -z "$REPO_DIR" ]; then
  echo "Usage: $0 <repository_directory>"
  exit 1
fi

cd "$REPO_DIR" || exit 1

echo "Syncing repository: $REPO_DIR"
git fetch
git reset --hard @{u}
git clean -fd
if ! git pull --ff-only; then
  echo "Pull failed in: $REPO_DIR"
  exit 1
fi
