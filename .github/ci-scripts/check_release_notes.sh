#!/usr/bin/env bash
# Release-notes gate.
#
# Convention: every published chart carries a `charts/<chart>/RELEASE.md` with a
# newest-first section per version, headed `## <version>`. Whenever a PR changes
# the `version:` field in `charts/<chart>/Chart.yaml`, that chart's RELEASE.md
# must gain a matching `## <new-version>` section in the same PR.
#
# This keeps the human-authored, per-chart notes in lockstep with the version
# bump, so the on-merge aggregation step has a section to read.
#
# Usage: check_release_notes.sh <base-ref>
#   base-ref defaults to origin/main.
set -euo pipefail

BASE_REF="${1:-origin/main}"

# Top-level `version:` from a Chart.yaml blob on stdin (empty if absent).
chart_version() { grep -E '^version:' | head -1 | sed -E 's/^version:[[:space:]]*//; s/[[:space:]]*$//' || true; }

fail=0
for chart_yaml in charts/*/Chart.yaml; do
  chart_dir="$(dirname "$chart_yaml")"
  chart_name="$(basename "$chart_dir")"

  new_version="$(chart_version < "$chart_yaml")"
  old_version="$(git show "${BASE_REF}:${chart_yaml}" 2>/dev/null | chart_version || true)"

  # Unchanged (or newly added chart with no base) → nothing to enforce.
  [ -n "$old_version" ] || continue
  [ "$new_version" != "$old_version" ] || continue

  echo "• ${chart_name}: version ${old_version} -> ${new_version}"

  release_md="${chart_dir}/RELEASE.md"
  if [ ! -f "$release_md" ]; then
    echo "  ✗ missing ${release_md} — add release notes with a '## ${new_version}' section"
    fail=1
    continue
  fi

  if ! grep -qE "^##[[:space:]]+${new_version}([[:space:]]|$)" "$release_md"; then
    echo "  ✗ ${release_md} has no '## ${new_version}' section for the new version"
    fail=1
    continue
  fi

  echo "  ✓ ${release_md} documents ${new_version}"
done

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "Release-notes gate failed. Every chart 'version:' bump must ship a matching"
  echo "'## <version>' section in that chart's RELEASE.md. See charts/CONVENTIONS.md."
  exit 1
fi

echo "Release-notes gate passed."
