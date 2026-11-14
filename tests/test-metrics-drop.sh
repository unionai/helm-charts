#!/usr/bin/env bash
# Scale's series (scale_*: the operator proxy's Ask Scale, watcher and store metrics) stay in the
# data plane. Prometheus scrapes them from the proxy's debug port (the union-services job), so every
# remote_write the dataplane chart renders in templates/prometheus/configmap.yaml must drop them:
# the zero-trust queue to the control plane and every queue set in prometheus.server.remoteWrite,
# also when its write_relabel_configs is empty. Mirrors T29 in unionai/cloud
# operator/deploy/helm/ci/check-scale-guards.sh.
#
# Two remote_writes the chart cannot add the drop to: kube-prometheus-stack's
# (monitoring.prometheus.prometheusSpec.remoteWrite) and the upstream prometheus ConfigMap's when
# prometheus.server.configMapOverrideName is emptied. For those, NOTES.txt and a rendered ConfigMap
# (union-scale-metrics-warning, so ArgoCD users see it too) name each queue that has no scale_.*
# drop (owner decisions 2026-11-13 18:08 and 18:40 IST: warn, never fail the render).
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

# warning NAME WANT HELM_ARGS...: the same warning in the rendered manifests, which is all ArgoCD
# (helm template) shows: a ConfigMap, union-scale-metrics-warning, whose union.ai/warning
# annotation says what is wrong and whose data names each queue. WANT as for notes.
warning() {
  local name=$1 want=$2
  shift 2
  if ! helm template t "$chart" -f "$values" "$@" >"$tmp/manifests" 2>"$tmp/err"; then
    echo "FAIL [warning: $name]: render failed"; cat "$tmp/err"; failures=$((failures + 1)); return
  fi
  awk '/^# Source: /{p=index($0, "templates/prometheus/scale-metrics-warning.yaml") > 0; next} /^---/{p=0} p' \
    "$tmp/manifests" >"$tmp/warning"
  if [ "$want" = none ]; then
    if [ -s "$tmp/warning" ]; then
      echo "FAIL [warning: $name]: renders the warning ConfigMap"; cat "$tmp/warning"; failures=$((failures + 1))
    fi
    return
  fi
  for text in "name: union-scale-metrics-warning" "union.ai/warning: " "scale_* metrics"; do
    if ! grep -qF -- "$text" "$tmp/warning"; then
      echo "FAIL [warning: $name]: the warning ConfigMap lacks '$text'"; cat "$tmp/warning"; failures=$((failures + 1)); return
    fi
  done
  local w
  while IFS= read -r w; do
    if ! grep -qF -- "$w" "$tmp/warning"; then
      echo "FAIL [warning: $name]: the warning ConfigMap does not name '$w'"; failures=$((failures + 1))
    fi
  done <<<"$want"
}

# notes NAME WANT HELM_ARGS...: renders NOTES.txt (helm install --dry-run=client, no cluster). WANT is
# "none" (no Scale warning), or the text each warning line must hold. The render must not fail.
# Every case is checked in the rendered manifests too (warning).
notes() {
  local name=$1 want=$2
  shift 2
  warning "$name" "$want" "$@"
  if ! KUBECONFIG=/dev/null helm install t "$chart" -f "$values" --dry-run=client "$@" >"$tmp/out" 2>"$tmp/err"; then
    echo "FAIL [notes: $name]: render failed"; cat "$tmp/err"; failures=$((failures + 1)); return
  fi
  sed -n '/^NOTES:$/,$p' "$tmp/out" >"$tmp/notes"
  if [ "$want" = none ]; then
    if grep -q "scale_" "$tmp/notes"; then
      echo "FAIL [notes: $name]: warns about scale_ metrics"; cat "$tmp/notes"; failures=$((failures + 1))
    fi
    return
  fi
  if ! grep -q "^WARNING: .*scale_\* metrics" "$tmp/notes"; then
    echo "FAIL [notes: $name]: no scale_* warning in NOTES"; failures=$((failures + 1)); return
  fi
  local w
  while IFS= read -r w; do
    if ! grep -qF -- "$w" "$tmp/notes"; then
      echo "FAIL [notes: $name]: NOTES does not name '$w'"; failures=$((failures + 1))
    fi
  done <<<"$want"
}

kps=prometheus.server.configMapOverrideName=
kp_own='{"url":"https://kp.example/push"}'
kp_dropped='{"url":"https://kp-dropped.example/push","writeRelabelConfigs":[{"sourceLabels":["__name__"],"regex":"scale_.*","action":"drop"}]}'
kp_keep='{"url":"https://kp-keep.example/push","writeRelabelConfigs":[{"sourceLabels":["__name__"],"regex":"scale_.*","action":"keep"}]}'
own_dropped='{"url":"https://amp-dropped.example/push","write_relabel_configs":[{"source_labels":["__name__"],"regex":"scale_.*","action":"drop"}]}'

notes "defaults" none
notes "zero trust on, own queue (the chart adds the drop)" none --set zero_trust.enabled=true --set-json "prometheus.server.remoteWrite=[$own]"
notes "kube-prometheus-stack off, queue set" none --set monitoring.enabled=false --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_own]"
notes "kube-prometheus-stack queue without the drop" "monitoring.prometheus.prometheusSpec.remoteWrite[0] https://kp.example/push" \
  --set monitoring.enabled=true --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_own]"
notes "kube-prometheus-stack queue with the drop" none \
  --set monitoring.enabled=true --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_dropped]"
notes "kube-prometheus-stack: one with, two without (one keeps scale_)" "$(printf '%s\n%s' \
  "monitoring.prometheus.prometheusSpec.remoteWrite[0] https://kp.example/push" \
  "monitoring.prometheus.prometheusSpec.remoteWrite[2] https://kp-keep.example/push")" \
  --set monitoring.enabled=true --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_own,$kp_dropped,$kp_keep]"
# Of those three, the queue that has the drop is not named.
if grep -qF "kp-dropped.example" "$tmp/notes"; then
  echo "FAIL [notes]: a queue with the drop is named"; failures=$((failures + 1))
fi
notes "emptied override, own queue without the drop" "prometheus.server.remoteWrite[0] https://amp.example/api/v1/remote_write" \
  --set "$kps" --set-json "prometheus.server.remoteWrite=[$own]"
notes "emptied override, own queue with the drop" none --set "$kps" --set-json "prometheus.server.remoteWrite=[$own_dropped]"
notes "emptied override, no queues" none --set "$kps"
notes "both at once" "$(printf '%s\n%s' \
  "monitoring.prometheus.prometheusSpec.remoteWrite[0] https://kp.example/push" \
  "prometheus.server.remoteWrite[0] https://amp.example/api/v1/remote_write")" \
  --set monitoring.enabled=true --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_own]" \
  --set "$kps" --set-json "prometheus.server.remoteWrite=[$own]"

# A queue's URL is named without the user, password or query it may carry (in NOTES and in the
# ConfigMap, which anyone who reads ConfigMaps in the namespace sees).
kp_creds='{"url":"https://scrape-user:not-a-real-password@kp-creds.example/push?token=not-a-real-token"}'
notes "kube-prometheus-stack queue with credentials in the URL" "monitoring.prometheus.prometheusSpec.remoteWrite[0] https://kp-creds.example/push" \
  --set monitoring.enabled=true --set-json "monitoring.prometheus.prometheusSpec.remoteWrite=[$kp_creds]"
for f in "$tmp/notes" "$tmp/warning"; do
  for secret in scrape-user not-a-real-password not-a-real-token; do
    if grep -qF -- "$secret" "$f"; then echo "FAIL [credentials]: $(basename "$f") holds '$secret'"; failures=$((failures + 1)); fi
  done
done

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "OK: every remote_write drops scale_.*, and NOTES names the ones the chart cannot change"
