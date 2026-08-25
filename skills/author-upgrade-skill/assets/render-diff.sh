#!/usr/bin/env bash
#
# Render the dataplane chart at two versions against each synthetic profile and diff the
# resulting object lists. Surfaces Class 5 (workload added/removed) changes that are
# invisible in a values diff.
#
# Usage:
#   ./render-diff.sh dataplane-2026.8.2 dataplane-2026.8.3
#
# Run from the repository root. Uses `git worktree` so your working tree is untouched.

set -euo pipefail

FROM_TAG="${1:-}"
TO_TAG="${2:-}"
if [[ -z "$FROM_TAG" || -z "$TO_TAG" ]]; then
  echo "usage: $0 <from-tag> <to-tag>   (e.g. dataplane-2026.8.2 dataplane-2026.8.3)" >&2
  exit 2
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SKILL_DIR/profiles"
OUT="$(mktemp -d)"
WT="$(mktemp -d)"

cleanup() {
  for t in "$FROM_TAG" "$TO_TAG"; do
    git worktree remove --force "$WT/$t" 2>/dev/null || true
  done
  rm -rf "$WT"
}
trap cleanup EXIT

echo "output: $OUT"
echo

for tag in "$FROM_TAG" "$TO_TAG"; do
  git worktree add --detach "$WT/$tag" "$tag" >/dev/null 2>&1
  # Subchart tarballs are not committed; pull them so `helm template` resolves deps.
  helm dependency build "$WT/$tag/charts/dataplane" >/dev/null 2>&1 \
    || echo "warning: dependency build failed for $tag (subchart objects will be absent)" >&2
done

status=0

for profile in "$PROFILE_DIR"/*.yaml; do
  name="$(basename "$profile" .yaml)"
  echo "=== profile: $name ==="

  for tag in "$FROM_TAG" "$TO_TAG"; do
    if ! helm template union-dataplane "$WT/$tag/charts/dataplane" \
        --namespace union \
        -f "$profile" \
        > "$OUT/$name.$tag.yaml" 2>"$OUT/$name.$tag.err"; then
      echo "  RENDER FAILED at $tag -- see $OUT/$name.$tag.err"
      echo "  A render that fails on only one version is itself a finding: an existing"
      echo "  customer values file will fail the same way. Capture the required key."
      status=1
      continue 2
    fi

    # Reduce to a sorted, deduplicated Kind/name list.
    python3 "$SKILL_DIR/objects.py" "$OUT/$name.$tag.yaml" > "$OUT/$name.$tag.objects"
  done

  if diff "$OUT/$name.$FROM_TAG.objects" "$OUT/$name.$TO_TAG.objects" > "$OUT/$name.objdiff"; then
    echo "  no object-list change"
    echo "  (content may still differ -- diff the manifests for Class 1/4 findings)"
  else
    sed 's/^/  /' "$OUT/$name.objdiff"
    echo
    echo "  '<' = removed in $TO_TAG   '>' = added in $TO_TAG"
  fi
  echo
done

cat <<MSG
Manifests and object lists: $OUT

Next: an unchanged object list does not mean nothing changed. Diff the manifest bodies
for defaults that moved inside a ConfigMap:

  diff "$OUT/<profile>.$FROM_TAG.yaml" "$OUT/<profile>.$TO_TAG.yaml"
MSG

exit $status
