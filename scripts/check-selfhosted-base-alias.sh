#!/usr/bin/env bash
# charts/onebox is published as an alias of charts/selfhosted-base (Self-hosted
# Base's name before the rename). The two must stay the same chart: identical
# files, except the name in Chart.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
diff -r -x Chart.yaml -x charts -x Chart.lock charts/selfhosted-base charts/onebox || status=1
if ! diff <(grep -v '^name:' charts/selfhosted-base/Chart.yaml) <(grep -v '^name:' charts/onebox/Chart.yaml); then
  status=1
fi
grep -qx 'name: selfhosted-base' charts/selfhosted-base/Chart.yaml || { echo "charts/selfhosted-base/Chart.yaml: name must be selfhosted-base"; status=1; }
grep -qx 'name: onebox' charts/onebox/Chart.yaml || { echo "charts/onebox/Chart.yaml: name must be onebox"; status=1; }
# A release installed from onebox, upgraded to selfhosted-base with
# nameOverride=onebox, keeps every resource name and selector label.
names() { # chart [helm args...]: kind/name and app.kubernetes.io/name of every resource
  local chart=$1; shift
  helm template onebox "charts/$chart" -n union --skip-tests --values tests/values/onebox.default.yaml "$@" \
    | python3 -c 'import sys,yaml
for d in yaml.safe_load_all(sys.stdin):
    if d: print(d["kind"], d["metadata"]["name"], (d["metadata"].get("labels") or {}).get("app.kubernetes.io/name",""))' | sort
}
if command -v helm >/dev/null; then
  for c in onebox selfhosted-base; do [[ -d charts/$c/charts ]] || helm dependency build "charts/$c" >/dev/null; done
  # Rendered to files, not process substitution, so a failed render (no PyYAML, a
  # template error) fails the check instead of comparing two empty lists.
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  names onebox >"$tmp/onebox"
  names selfhosted-base --set nameOverride=onebox >"$tmp/selfhosted-base"
  if [[ ! -s $tmp/onebox ]]; then
    echo "rendering charts/onebox produced no resources" >&2; status=1
  elif ! diff "$tmp/onebox" "$tmp/selfhosted-base"; then
    echo "selfhosted-base with nameOverride=onebox renders different names than onebox" >&2; status=1
  fi
fi
if [[ $status -ne 0 ]]; then
  echo "charts/onebox and charts/selfhosted-base differ: change charts/selfhosted-base, then copy it to charts/onebox (keeping name: onebox)." >&2
fi
exit $status
