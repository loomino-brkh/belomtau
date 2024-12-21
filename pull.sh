#!/bin/bash

DIRECTORY="$1"

if [ -z "$DIRECTORY" ]; then
  echo "Usage: $0 <directory>"
  exit 1
fi

monitor_and_pull() {
  find "$DIRECTORY" -type d -name ".git" 2>/dev/null | while read -r git_dir; do
    repo_dir=$(dirname "$git_dir")
    bash "$(dirname "$0")/git_pull.sh" "$repo_dir" &
  done
  wait
}

while true; do
  monitor_and_pull
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Monitoring $DIRECTORY for changes..."
  sleep 15
done
