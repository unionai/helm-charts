#!/usr/bin/env bash
#
# Generate release notes for newly released helm charts.
#
# In CI, pass EXISTING_TAGS (comma-separated) to limit updates to only
# tags created during this run. Without it, all charts are processed.
#
# Usage:
#   ./scripts/generate-release-notes.sh                  # dry-run: prints notes to stdout
#   ./scripts/generate-release-notes.sh --publish         # updates GitHub releases via gh CLI
#   EXISTING_TAGS="tag1,tag2," ./scripts/generate-release-notes.sh --publish
#
set -euo pipefail

publish=false
if [[ "${1:-}" == "--publish" ]]; then
  publish=true
fi

for chart_dir in charts/*/; do
  chart_name=$(basename "$chart_dir")
  chart_version=$(grep '^version:' "$chart_dir/Chart.yaml" | awk '{print $2}')
  tag="${chart_name}-${chart_version}"

  # If EXISTING_TAGS is set, skip tags that already existed (only process new releases)
  if [[ -n "${EXISTING_TAGS:-}" ]]; then
    if echo "$EXISTING_TAGS" | grep -q "${tag}"; then
      continue
    fi

    # Skip if release wasn't created
    if ! gh release view "$tag" &>/dev/null; then
      continue
    fi
  fi

  # Find previous release tag for this chart (exact name match to avoid e.g. dataplane matching dataplane-crds)
  prev_tag=$(git tag -l "${chart_name}-*" --sort=-v:refname | grep -E "^${chart_name}-[0-9]" | grep -v "^${tag}$" | head -1)

  if [ -n "$prev_tag" ]; then
    notes=$(git log "${prev_tag}..HEAD" --pretty=format:"- %s (%h)" -- "$chart_dir")
  else
    notes=$(git log --pretty=format:"- %s (%h)" -- "$chart_dir" | head -50)
  fi

  if [ -z "$notes" ]; then
    continue
  fi

  formatted=$(printf "## Changes\n\n%s\n" "$notes")

  if [[ "$publish" == true ]]; then
    echo "Updating release notes for ${tag}"
    printf "%s" "$formatted" | gh release edit "$tag" --notes-file -
  else
    echo "=== ${tag} (since ${prev_tag:-<initial>}) ==="
    echo "$formatted"
    echo ""
  fi
done
