#!/usr/bin/env bash
#
# Render Helm templates at two git refs and structurally diff the output.
#
# Mirrors the ArgoCD values layering for selfhosted deployments so you can
# verify exactly what will change before deploying.
#
# Usage:
#   ./scripts/render-and-diff.sh <old-ref> <new-ref> [options]
#
# Examples:
#   # Compare latest release tag against main
#   ./scripts/render-and-diff.sh controlplane-2026.4.7 main
#
#   # Compare two branches for a specific chart
#   ./scripts/render-and-diff.sh main mike/feature --chart dataplane
#
#   # Use custom values (e.g. terraform-generated)
#   ./scripts/render-and-diff.sh controlplane-2026.4.7 main \
#     --values /path/to/terraform/control-plane/values.yaml
#
#   # Compare with test fixture values
#   ./scripts/render-and-diff.sh controlplane-2026.4.7 main \
#     --values tests/values/controlplane.aws.yaml
#
#   # Diff all resources, not just ConfigMaps
#   ./scripts/render-and-diff.sh controlplane-2026.4.7 main --all
#
#   # Text diff instead of structural
#   ./scripts/render-and-diff.sh controlplane-2026.4.7 main --text
#
# Requires: helm, python3, PyYAML (pip install pyyaml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
CHART="controlplane"
VALUES_FILES=()
DIFF_ALL=false
TEXT_DIFF=false
NAMESPACE=""
EXTRA_HELM_ARGS=()

usage() {
  sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p }' "$0"
  exit "${1:-0}"
}

# Parse args
if [ $# -lt 2 ]; then
  usage 1
fi

OLD_REF="$1"
NEW_REF="$2"
shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --chart)
      CHART="$2"; shift 2 ;;
    --values)
      VALUES_FILES+=("$2"); shift 2 ;;
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    --all)
      DIFF_ALL=true; shift ;;
    --text)
      TEXT_DIFF=true; shift ;;
    --help|-h)
      usage 0 ;;
    --set|--set-string)
      EXTRA_HELM_ARGS+=("$1" "$2"); shift 2 ;;
    *)
      echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# Set namespace default based on chart
if [ -z "$NAMESPACE" ]; then
  case "$CHART" in
    controlplane) NAMESPACE="controlplane" ;;
    dataplane)    NAMESPACE="dataplane" ;;
    *)            NAMESPACE="union" ;;
  esac
fi

# If no values files specified, use the default test fixture
if [ ${#VALUES_FILES[@]} -eq 0 ]; then
  DEFAULT_VALUES="$REPO_ROOT/tests/values/${CHART}.aws.yaml"
  if [ -f "$DEFAULT_VALUES" ]; then
    VALUES_FILES=("$DEFAULT_VALUES")
    echo "Using default test values: tests/values/${CHART}.aws.yaml"
  else
    echo "Warning: no --values specified and no default test fixture found at $DEFAULT_VALUES"
  fi
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

render() {
  local ref="$1"
  local outfile="$2"

  # Create a worktree for the ref
  local worktree="$TMPDIR/worktree-$(echo "$ref" | tr '/' '-')"
  git -C "$REPO_ROOT" worktree add --quiet --detach "$worktree" "$ref" 2>/dev/null

  # Build values flags — resolve paths relative to CWD (not worktree)
  local values_args=()
  for vf in "${VALUES_FILES[@]}"; do
    local abs_path
    if [[ "$vf" = /* ]]; then
      abs_path="$vf"
    elif [[ "$vf" = tests/* ]]; then
      # Test fixtures: use from worktree so they match the ref
      abs_path="$worktree/$vf"
    else
      abs_path="$(cd "$REPO_ROOT" && realpath "$vf")"
    fi

    if [ ! -f "$abs_path" ]; then
      echo "Warning: values file not found at ref $ref: $vf (skipping)" >&2
      continue
    fi
    values_args+=(--values "$abs_path")
  done

  # Build chart dependencies
  helm dependency build "$worktree/charts/$CHART" --skip-refresh >/dev/null 2>&1 || true

  # Add controlplane-specific defaults
  local chart_args=()
  if [ "$CHART" = "controlplane" ]; then
    chart_args+=(--set secrets.admin.clientSecret=test-secret)
  fi

  helm template "$worktree/charts/$CHART" \
    --name-template "$CHART" \
    --namespace "$NAMESPACE" \
    --kube-version 1.32 \
    "${values_args[@]}" \
    "${chart_args[@]}" \
    "${EXTRA_HELM_ARGS[@]}" \
    > "$outfile"

  git -C "$REPO_ROOT" worktree remove --force "$worktree" 2>/dev/null
}

echo "Rendering $CHART chart..."
echo "  old: $OLD_REF"
echo "  new: $NEW_REF"
echo ""

OLD_OUT="$TMPDIR/old.yaml"
NEW_OUT="$TMPDIR/new.yaml"

render "$OLD_REF" "$OLD_OUT"
echo "  [ok] $OLD_REF rendered"

render "$NEW_REF" "$NEW_OUT"
echo "  [ok] $NEW_REF rendered"
echo ""

if $TEXT_DIFF; then
  echo "=== Text diff ==="
  diff -u "$OLD_OUT" "$NEW_OUT" || true
else
  COMPARE_ARGS=()
  if $DIFF_ALL; then
    COMPARE_ARGS+=(--all)
  fi
  python3 "$SCRIPT_DIR/compare-manifests.py" "$OLD_OUT" "$NEW_OUT" "${COMPARE_ARGS[@]}"
fi
