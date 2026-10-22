#!/usr/bin/env bash
# Checks the Scale guards in charts/dataplane/templates/scale/_scale.tpl: settings that turn fixes
# or pushes on, in any spelling the runtime's case-insensitive config loader accepts, must fail
# the render unless every security requirement is met; the agent must fail without its signing
# key, its view-only app, a model endpoint or app serving; complete settings must render, and
# Scale renders nothing when it is off. Mirrors operator/deploy/helm/ci/check-scale-guards.sh in
# unionai/cloud.
#
#   tests/test-scale-guards.sh
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
chart="${SCRIPT_DIR}/../charts/dataplane"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/scale-guards.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/base.yaml" <<'YAML'
global:
  CONTROLPLANE_HOST: test-controlplane-host
  CLUSTER_NAME: test-cluster-name
  ORG_NAME: test-org-name
  AUTH_CLIENT_ID: test-auth-client-id
  METADATA_BUCKET: test-metadata-bucket
  FAST_REGISTRATION_BUCKET: test-fast-registration-bucket
secrets:
  admin:
    clientSecret: test-not-real-secret
YAML

cat > "$tmp/secure.yaml" <<'YAML'
scale:
  enabled: true
  auth: {appId: acme-dp-1-scale}
  signing: {secretName: scale-signing}
  callerAuth: {secretName: scale-caller}
  storageContainer: acme-scale
  serviceAccount: {create: true}
  proxyNetworkPolicy: {enabled: true}
  fixWriter: {secretName: union-scale-fix-writer}
YAML

cat > "$tmp/agent.yaml" <<'YAML'
apps:
  enabled: true
scale:
  enabled: true
  auth: {appId: acme-dp-1-scale}
  signing: {secretName: scale-signing}
  agent:
    enabled: true
    model: {baseURL: "http://llm-gateway.union.svc.cluster.local/v1"}
YAML

render() { helm template t "$chart" --namespace union -f "$tmp/base.yaml" "$@" >"$tmp/out" 2>"$tmp/err"; }
failures=0
must_render() {
  if ! render "$@"; then echo "FAIL: should render: $*"; cat "$tmp/err"; failures=$((failures + 1)); fi
}
must_fail() {
  local want="$1"; shift
  if render "$@"; then echo "FAIL: should not render: $*"; failures=$((failures + 1));
  elif ! grep -q "$want" "$tmp/err"; then echo "FAIL: $* failed without \"$want\":"; cat "$tmp/err"; failures=$((failures + 1)); fi
}
# must_contain <text> <helm args...>: renders, and the output holds text.
must_contain() {
  local want="$1"; shift
  must_render "$@"
  if ! grep -qF -- "$want" "$tmp/out"; then echo "FAIL: $* rendered without \"$want\""; failures=$((failures + 1)); fi
}
# must_not_contain <text> <helm args...>: renders, and the output does not hold text.
must_not_contain() {
  local want="$1"; shift
  must_render "$@"
  if grep -qF -- "$want" "$tmp/out"; then echo "FAIL: $* rendered \"$want\""; failures=$((failures + 1)); fi
}

# Off by default: nothing of Scale renders.
for text in "app: scale" "/etc/union/scale-" "SCALE_"; do
  must_not_contain "$text" --set apps.enabled=true --set zero_trust.enabled=true
done
must_render --set scale.enabled=true
must_render -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true
must_render -f "$tmp/secure.yaml" --set scale.git.enabled=true --set scale.git.github.appId=1

# Every way to turn writes on goes through the guards.
for on in scale.config.fix.enabled scale.git.enabled; do
  must_fail "scale.auth.appId" --set scale.enabled=true --set "$on=true"
done
must_fail "not scale.config.git" --set scale.enabled=true --set scale.config.git.enabled=true
for spelling in scale.config.Fix.enabled scale.config.FIX.enabled scale.config.fix.Enabled scale.config.Git.enabled scale.git.Enabled; do
  must_fail "only read lowercase" -f "$tmp/secure.yaml" --set "$spelling=true"
done

# Each requirement on its own.
must_fail "proxyNetworkPolicy" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.proxyNetworkPolicy.enabled=false
must_fail "callerAuth" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.callerAuth.secretName=
must_fail "signing.secretName" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.signing.secretName=
must_fail "storageContainer" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.storageContainer=
must_fail "serviceAccount.create" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.serviceAccount.create=false
must_fail "fixWriter" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.fixWriter.secretName=
must_fail "stay off while" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true --set scale.signing.acceptUnsignedUntil=2026-11-01T00:00:00Z
must_fail "needs scale.storageContainer" --set scale.enabled=true --set scale.signing.acceptUnsignedUntil=2026-11-01T00:00:00Z
must_fail "needs orgName" --set scale.enabled=true --set global.ORG_NAME=
must_fail "storage.enableMultiContainer" --set scale.enabled=true --set scale.storageContainer=acme-scale --set storage.enableMultiContainer=false

# The rendered guards match what they guard: the NetworkPolicy the guard requires is rendered,
# Scale's secrets are mounted 0440 and readable through fsGroup 65532.
must_contain "name: union-operator-proxy-scale" -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true
must_contain "defaultMode: 0440" -f "$tmp/secure.yaml"
must_contain "fsGroup: 65532" -f "$tmp/secure.yaml"
must_contain "callerKeyPath: /etc/union/scale-caller/caller-key" -f "$tmp/secure.yaml"
must_contain "callerKeyPath: /etc/union/scale-caller/caller-key" -f "$tmp/secure.yaml" --set zero_trust.enabled=true

# The agent: scales to zero, no GPU, and only with its key, its view-only app, a model and app
# serving.
must_contain 'autoscaling.knative.dev/min-scale: "0"' -f "$tmp/agent.yaml"
must_not_contain "nvidia.com/gpu" -f "$tmp/agent.yaml"
must_contain "url: http://scale-agent.union.svc.cluster.local" -f "$tmp/agent.yaml"
must_fail "scale.agent needs scale.signing.secretName" -f "$tmp/agent.yaml" --set scale.signing.secretName=
must_fail "scale.agent needs scale.auth.appId" -f "$tmp/agent.yaml" --set scale.auth.appId=
must_fail "scale.agent.model.baseURL is required" -f "$tmp/agent.yaml" --set scale.agent.model.baseURL=
must_fail "needs app serving" -f "$tmp/agent.yaml" --set apps.enabled=false
# Its NetworkPolicy admits the internal gateway of the serving path in use.
must_contain "- gateway" -f "$tmp/agent.yaml"
must_contain "- 3scale-kourier-gateway" -f "$tmp/agent.yaml" --set zero_trust.enabled=false --set gateway.enabled=false --set knative-operator.enabled=true

if [ "$failures" -gt 0 ]; then echo "$failures Scale guard check(s) failed"; exit 1; fi
echo "Scale guards OK"
