#!/usr/bin/env bash
# Pre-commit hook: ensure that whenever appVersion is bumped in a Chart.yaml,
# the chart version is also bumped. Helm uses `version` for caching and
# upgrade decisions, so changing only appVersion can cause clients to serve
# a stale cached chart.

set -euo pipefail

rc=0

for file in "$@"; do
  # Only care about Chart.yaml files
  [[ "$(basename "$file")" == "Chart.yaml" ]] || continue

  # Get the diff for this file (staged changes)
  diff_output=$(git diff --cached -- "$file" 2>/dev/null || true)
  [ -z "$diff_output" ] && continue

  app_version_changed=$(echo "$diff_output" | grep -cE '^\+appVersion:' || true)
  version_changed=$(echo "$diff_output" | grep -cE '^\+version:' || true)

  if [ "$app_version_changed" -gt 0 ] && [ "$version_changed" -eq 0 ]; then
    echo "ERROR: $file has appVersion change without a version bump."
    echo "  Helm uses 'version' for caching and upgrade decisions."
    echo "  Bump 'version' alongside 'appVersion' to avoid serving stale charts."
    rc=1
  fi
done

exit $rc