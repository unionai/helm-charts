#!/usr/bin/env bash
# Scale's series (scale_*: the operator proxy's Ask Scale, watcher and store metrics) stay in the
# data plane. Prometheus scrapes them from the proxy's debug port (the union-services job), so every
# remote_write the dataplane chart renders in templates/prometheus/configmap.yaml must drop them:
# the zero-trust queue to the control plane and every queue set in prometheus.server.remoteWrite,
# also when its write_relabel_configs is empty. Mirrors T29 in unionai/cloud
# operator/deploy/helm/ci/check-scale-guards.sh.
#
#   tests/test-metrics-drop.sh
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
chart="${SCRIPT_DIR}/../charts/dataplane"
values="${SCRIPT_DIR}/values/dataplane.aws.yaml"
cm=templates/prometheus/configmap.yaml
tmp="$(mktemp -d "${TMPDIR:-/tmp}/metrics-drop.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0

# check NAME WANT_QUEUES HELM_ARGS...: renders the ConfigMap and checks that it has WANT_QUEUES
# remote_write queues and that each one has the drop rule for scale_.* in its write_relabel_configs.
check() {
  local name=$1 want=$2
  shift 2
  if ! helm template t "$chart" -f "$values" --show-only "$cm" "$@" >"$tmp/out" 2>"$tmp/err"; then
    echo "FAIL [$name]: render failed"; cat "$tmp/err"; failures=$((failures + 1)); return
  fi
  # One line per queue: "<url> <has drop 0|1>". A queue starts at "    - " inside remote_write:
  # and the block ends at the next key at the same indent as remote_write.
  awk '
    function end_rule() { if (action == "drop" && regex == "scale_.*" && name) drop = 1; in_rule = 0; action = regex = ""; name = 0 }
    function end_queue() { end_rule(); if (n) print url, drop }
    /^    remote_write:$/ { in_rw = 1; next }
    in_rw && /^    [a-z_]+:/ { in_rw = 0 }
    !in_rw { next }
    /^    - / { end_queue(); n++; url = "?"; drop = 0; sub(/^    - /, "      ") }
    /^      url: / { url = $2 }
    /^      - / { end_rule(); in_rule = 1; sub(/^      - /, "        ") }
    /^      [a-z_]+:/ { end_rule() }
    in_rule && /^        action: / { action = $2 }
    in_rule && /^        regex: / { regex = $2 }
    in_rule && /^        - __name__$/ { name = 1 }
    END { end_queue() }
  ' "$tmp/out" >"$tmp/queues"
  local got
  got=$(wc -l <"$tmp/queues" | tr -d " ")
  if [ "$got" != "$want" ]; then
    echo "FAIL [$name]: $got remote_write queues, want $want"; failures=$((failures + 1))
  fi
  while read -r url drop; do
    if [ "$drop" != 1 ]; then
      echo "FAIL [$name]: remote_write $url does not drop scale_.*"; failures=$((failures + 1))
    fi
  done <"$tmp/queues"
}

own='{"url":"https://amp.example/api/v1/remote_write"}'
own_empty='{"url":"https://amp.example/api/v1/remote_write","write_relabel_configs":[]}'
own_keep='{"url":"https://amp.example/api/v1/remote_write","write_relabel_configs":[{"source_labels":["__name__"],"regex":"up|scale_.*","action":"keep"}]}'
other='{"url":"https://other.example/push"}'

check "zero trust on" 1 --set zero_trust.enabled=true
check "zero trust off" 0 --set zero_trust.enabled=false
check "zero trust off, own queue" 1 --set zero_trust.enabled=false --set-json "prometheus.server.remoteWrite=[$own]"
check "zero trust off, own queue, empty relabel list" 1 --set zero_trust.enabled=false --set-json "prometheus.server.remoteWrite=[$own_empty]"
check "zero trust on, own queue that keeps scale_" 2 --set zero_trust.enabled=true --set-json "prometheus.server.remoteWrite=[$own_keep]"
check "zero trust on, two own queues" 3 --set zero_trust.enabled=true --set-json "prometheus.server.remoteWrite=[$own,$other]"

# The values' own rules stay, before the drop.
helm template t "$chart" -f "$values" --show-only "$cm" --set zero_trust.enabled=false \
  --set-json "prometheus.server.remoteWrite=[$own_keep]" >"$tmp/out" 2>"$tmp/err" || { cat "$tmp/err"; failures=$((failures + 1)); }
if ! grep -qx '        regex: up|scale_.\*' "$tmp/out"; then
  echo "FAIL: the queue's own write_relabel_configs rule is gone"; failures=$((failures + 1))
fi
# The values are not changed by the render: a second queue does not get the first one's rules twice.
if [ "$(grep -cx '        regex: scale_.\*' "$tmp/out")" != 1 ]; then
  echo "FAIL: the drop rule is not there exactly once"; failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "OK: every remote_write drops scale_.*"
