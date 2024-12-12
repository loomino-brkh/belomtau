#!/bin/bash

DIRECTORY="$1"

if [ -z "$DIRECTORY" ]; then
  echo "Usage: $0 <directory>"
  exit 1
fi

monitor_and_pull() {
  find "$DIRECTORY" -type d -name ".git" | while read -r git_dir; do
    repo_dir=$(dirname "$git_dir")
    cd "$repo_dir" || continue
    git fetch
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})
    BASE=$(git merge-base @ @{u})

    if [ "$LOCAL" = "$REMOTE" ]; then
      echo "Up to date: $repo_dir"
    elif [ "$LOCAL" = "$BASE" ]; then
      echo "Pulling updates in: $repo_dir"
      if ! git pull; then
        echo "Pull failed, attempting to reset and pull again in: $repo_dir"
        git reset --hard HEAD
        git clean -fd
        if ! git pull; then
          echo "Pull still failed after reset in: $repo_dir"
        fi
      fi
    else
      echo "Local changes present in: $repo_dir"
    fi
    cd - >/dev/null || continue
  done
}

while true; do
  monitor_and_pull
  sleep 45
done
