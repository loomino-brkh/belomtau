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
    
    echo "Syncing repository: $repo_dir"
    git fetch
    # Reset to remote state and clean workspace
    git reset --hard @{u}
    git clean -fd
    # Pull any remaining changes
    if ! git pull --ff-only; then
      echo "Pull failed in: $repo_dir"
    fi
    
    cd - >/dev/null || continue
  done
}

while true; do
  monitor_and_pull
  sleep 45
done
