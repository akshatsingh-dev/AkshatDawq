#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: scripts/quick-push.sh \"commit message\""
  exit 1
fi

msg="$1"

git add -A

if git diff --cached --quiet; then
  echo "No staged changes to commit."
  exit 0
fi

git commit -m "$msg"
git push

echo "Committed and pushed: $msg"
