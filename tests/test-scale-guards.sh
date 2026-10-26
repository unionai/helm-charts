#!/usr/bin/env bash
# Checks the Scale guards in charts/dataplane/templates/scale/_scale.tpl: settings that turn fixes
# or pushes on, in any spelling the runtime's case-insensitive config loader accepts, must fail
# the render unless every security requirement is met; the agent must fail without its signing
# key, its view-only app or app serving; complete settings must render, and Scale renders nothing
# when it is off. The agent's model guards (templates/scale/_agent.tpl): each provider renders with
# what it needs and fails with a plain message without it, the console's settings are used only
# when the values set no key and the proxy has a secret store, the agent's egress policy allows
# only what the provider needs, and the replica bounds (minScale, maxScale) stay in order. Mirrors
# operator/deploy/helm/ci/check-scale-guards.sh and check-scale-agent-guards.sh in unionai/cloud.
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
# Scale needs a caller key or the proxy NetworkPolicy before it serves anything; checked on its own
# below.
scale:
  callerAuth: {secretName: scale-caller}
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

# What the agent needs whatever the provider, then each provider's settings.
cat > "$tmp/agent-base.yaml" <<'YAML'
apps:
  enabled: true
scale:
  enabled: true
  auth: {appId: acme-dp-1-scale}
  signing: {secretName: scale-signing}
  agent:
    enabled: true
YAML
cat > "$tmp/anthropic.yaml" <<'YAML'
scale:
  agent:
    model:
      provider: anthropic
      apiKeySecret: {name: scale-agent-model, key: api-key}
YAML
cat > "$tmp/openai.yaml" <<'YAML'
scale:
  agent:
    model:
      provider: openai
      baseURL: https://llm-gateway.example.com/v1
YAML
cat > "$tmp/egress.yaml" <<'YAML'
scale:
  agent:
    networkPolicy:
      egress:
        enabled: true
        controlPlaneCIDRs: [203.0.113.0/24]
YAML
cat > "$tmp/gateway-egress.yaml" <<'YAML'
scale:
  agent:
    networkPolicy:
      egress:
        model:
          - to: [{ipBlock: {cidr: 198.51.100.7/32}}]
            ports: [{protocol: TCP, port: 443}]
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
# One rendered template of the last render, then a check that it contains (or lacks) a string.
# grep reads it all (no -q), so awk never dies of SIGPIPE under pipefail.
source_of() { awk -v f="$1" '/^# Source: /{p=(index($0, f) > 0); next} /^---/{p=0} p' "$tmp/out"; }
policy() { source_of templates/scale/agent-networkpolicy.yaml; }
service() { source_of templates/scale/agent-service.yaml; }
proxyconfig() { source_of templates/operator/configmap.yaml; }
scaleconfig() { source_of templates/scale/configmap.yaml; }
proxydeploy() { source_of templates/operator/deployment-proxy.yaml; }
expect() {
  local where="$1" want="$2"
  if ! "$where" | grep -F -- "$want" >/dev/null; then echo "FAIL: $where lacks \"$want\""; failures=$((failures + 1)); fi
}
expect_not() {
  local where="$1" want="$2"
  if "$where" | grep -F -- "$want" >/dev/null; then echo "FAIL: $where has \"$want\""; failures=$((failures + 1)); fi
}

# Off by default: nothing of Scale renders.
for text in "app: scale" "/etc/union/scale-" "SCALE_"; do
  must_not_contain "$text" --set apps.enabled=true --set zero_trust.enabled=true
done
must_render --set scale.enabled=true
must_render -f "$tmp/secure.yaml" --set scale.config.fix.enabled=true
must_render -f "$tmp/secure.yaml" --set scale.git.enabled=true --set scale.git.github.appId=1

# Scale needs a caller key or the proxy NetworkPolicy, whatever else is on.
must_fail "callerAuth.secretName or scale.proxyNetworkPolicy.enabled" --set scale.enabled=true --set scale.callerAuth.secretName= --set scale.proxyNetworkPolicy.enabled=false
# The proxy NetworkPolicy is on by default, so Scale with defaults keeps task pods off the proxy,
# and its debug port (the profiler) is open only to the release namespace and metricsFrom: both
# ingress rules name who may connect.
proxypolicy() { source_of templates/scale/networkpolicy-proxy.yaml; }
must_render --set scale.enabled=true --set scale.callerAuth.secretName=
expect proxypolicy "kind: NetworkPolicy"
expect proxypolicy "kubernetes.io/metadata.name: monitoring"
froms=$(proxypolicy | grep -c -- "- from:" || true)
if [ "$froms" != 2 ]; then echo "FAIL: the proxy NetworkPolicy has $froms from rules, want 2"; failures=$((failures + 1)); fi
must_render --set scale.enabled=true --set scale.callerAuth.secretName= --set scale.proxyNetworkPolicy.enabled=true
must_fail "callerAuth.secretName or scale.proxyNetworkPolicy.enabled" -f "$tmp/secure.yaml" \
  --set scale.callerAuth.secretName= --set scale.proxyNetworkPolicy.enabled=false

# A serverless (multi-org) cluster refuses Scale until caller keys are per org, by either marker; a
# cluster without Scale still renders.
crm=clusterresourcesync.config
must_fail "serverless (multi-org)" -f "$tmp/secure.yaml" --set "$crm.clusterResourcesPrivate.app.isServerless=true"
must_fail "serverless (multi-org)" -f "$tmp/secure.yaml" --set "$crm.cluster_resources.isServerless=true"
must_render -f "$tmp/secure.yaml" --set "$crm.clusterResourcesPrivate.app.isServerless=false"
must_render --set "$crm.clusterResourcesPrivate.app.isServerless=true" --set "$crm.cluster_resources.isServerless=true"

# Every way to turn writes on goes through the guards.
for on in scale.config.fix.enabled scale.git.enabled; do
  must_fail "scale.auth.appId" --set scale.enabled=true --set "$on=true"
done
# Jobs are off by default, and setting their image turns them on like a write: with only caller
# auth the render fails; with everything fixes need it renders.
must_render --set scale.enabled=true
expect_not scaleconfig "jobs:"
must_fail "scale.auth.appId" --set scale.enabled=true --set scale.jobs.image.repository=scale-job
must_fail "fixWriter" -f "$tmp/secure.yaml" --set scale.jobs.image.repository=scale-job --set scale.fixWriter.secretName=
must_fail "proxyNetworkPolicy" -f "$tmp/secure.yaml" --set scale.jobs.image.repository=scale-job --set scale.proxyNetworkPolicy.enabled=false
must_fail "serviceAccount.create" -f "$tmp/secure.yaml" --set scale.jobs.image.repository=scale-job --set scale.serviceAccount.create=false
# Scale never starts a job by itself unless the values say so, and a job's evidence holds a log
# tail only where the agent may read logs.
must_render -f "$tmp/secure.yaml" --set scale.jobs.image.repository=scale-job
expect scaleconfig "autoStart: false"
expect scaleconfig "readLogs: true"
must_render -f "$tmp/secure.yaml" --set scale.jobs.image.repository=scale-job --set scale.jobs.autoStart=true --set scale.agent.readLogs=false
expect scaleconfig "autoStart: true"
expect scaleconfig "readLogs: false"
# useRuntimeCredentials stands in for the writer only in the dogfood org.
must_fail "dogfood org only" -f "$tmp/secure.yaml" --set scale.fixWriter.secretName= --set scale.config.fix.enabled=true \
  --set scale.config.fix.writer.useRuntimeCredentials=true
must_render -f "$tmp/secure.yaml" --set scale.fixWriter.secretName= --set scale.config.fix.enabled=true \
  --set scale.config.fix.writer.useRuntimeCredentials=true --set global.ORG_NAME=dogfood

# scale.git's commit author, poll interval and read limits reach the runtime's config; unset, the
# runtime's defaults apply.
git_on=(-f "$tmp/secure.yaml" --set scale.git.enabled=true --set scale.git.github.appId=1)
must_render "${git_on[@]}" --set scale.git.authorName="Acme Bot" --set scale.git.authorEmail=bot@acme.com \
  --set scale.git.pollInterval=30s --set scale.git.maxFiles=500 --set scale.git.maxFileBytes=2097152
for want in 'authorName: "Acme Bot"' 'authorEmail: "bot@acme.com"' 'pollInterval: "30s"' 'maxFiles: 500' 'maxFileBytes: 2097152'; do
  expect scaleconfig "$want"
done
must_render "${git_on[@]}"
for unset in authorName pollInterval maxFiles; do expect_not scaleconfig "$unset"; done

# 0 daily diagnoses means no cap (-1 to the runtime), as in the operator chart.
must_render -f "$tmp/agent.yaml" --set scale.agent.dailyDiagnoses=0
expect scaleconfig "dailyDiagnoses: -1"
must_render -f "$tmp/agent.yaml"
expect scaleconfig "dailyDiagnoses: 20"
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
# A missing or misnamed signing or caller key secret leaves the operator proxy starting.
must_render -f "$tmp/secure.yaml"
for secret in scale-signing scale-caller; do
  if ! proxydeploy | grep -A1 -F "secretName: $secret" | grep -F "optional: true" >/dev/null; then
    echo "FAIL: the operator proxy's $secret volume is not optional"; failures=$((failures + 1))
  fi
done
# scale.callerAuth.requireDigest reaches the operator proxy's config, and only when it is on.
must_render -f "$tmp/secure.yaml" --set scale.callerAuth.requireDigest=true
expect proxyconfig "requireDigest: true"
must_render -f "$tmp/secure.yaml"
expect_not proxyconfig "requireDigest"

# Issues are priced for the cluster's cloud: provider, else gcp with GCS storage; a cloud set in
# scale.config wins, and with neither the runtime keeps the usage price table's own (AWS).
must_render --set scale.enabled=true --set provider=gcp
expect scaleconfig "cloud: gcp"
must_render --set scale.enabled=true --set storage.provider=gcs --set storage.gcp.projectId=p
expect scaleconfig "cloud: gcp"
must_render --set scale.enabled=true --set provider=azure --set scale.config.detectors.cost.cloud=aws
expect scaleconfig "cloud: aws"
expect_not scaleconfig "cloud: azure"
must_render --set scale.enabled=true
expect_not scaleconfig "cloud:"

# The agent: scales to zero, no GPU, and only with its key, its view-only app, a model and app
# serving.
must_contain 'autoscaling.knative.dev/min-scale: "0"' -f "$tmp/agent.yaml"
must_not_contain "nvidia.com/gpu" -f "$tmp/agent.yaml"
must_contain "url: http://scale-agent.union.svc.cluster.local" -f "$tmp/agent.yaml"
must_fail "scale.agent needs scale.signing.secretName" -f "$tmp/agent.yaml" --set scale.signing.secretName=
must_fail "scale.agent needs scale.auth.appId" -f "$tmp/agent.yaml" --set scale.auth.appId=
must_fail "needs app serving" -f "$tmp/agent.yaml" --set apps.enabled=false
# Its NetworkPolicy admits the internal gateway of the serving path in use.
must_contain "- gateway" -f "$tmp/agent.yaml"
must_contain "- 3scale-kourier-gateway" -f "$tmp/agent.yaml" --set zero_trust.enabled=false --set gateway.enabled=false --set knative-operator.enabled=true

# The agent's model (templates/scale/_agent.tpl). Without a secret store the values decide the
# model; the dataplane's proxy has one by default (proxy.secretManager.enabled).
nostore=(--set proxy.secretManager.enabled=false)
# Each provider renders with what it needs, and tells the agent which it is.
must_render -f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml"
expect service 'value: "anthropic"'
expect service 'SCALE_AGENT_MODEL_API_KEY_FILE'
expect service 'SCALE_AGENT_MODEL_EFFORT'
expect_not service 'SCALE_AGENT_MODEL_BASE_URL'
expect_not policy 'Egress'
expect service 'value: "claude-opus-5-5"'
must_render -f "$tmp/agent-base.yaml" -f "$tmp/openai.yaml"
expect service 'value: "openai"'
expect service 'value: "https://llm-gateway.example.com/v1"'
expect_not service 'SCALE_AGENT_MODEL_EFFORT'

# Each provider without what it needs.
must_fail "provider anthropic needs scale.agent.model.apiKeySecret.name" -f "$tmp/agent-base.yaml" "${nostore[@]}" --set scale.agent.model.provider=anthropic
must_fail "provider openai needs scale.agent.model.baseURL" -f "$tmp/agent-base.yaml" "${nostore[@]}" --set scale.agent.model.provider=openai
must_fail "provider openai needs scale.agent.model.baseURL" -f "$tmp/agent.yaml" "${nostore[@]}" --set scale.agent.model.baseURL=
must_fail 'provider must be anthropic or openai, not "bedrock"' -f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml" --set scale.agent.model.provider=bedrock
must_fail "effort must be low, medium, high, xhigh, max or empty" -f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml" --set scale.agent.model.effort=extreme

# Replicas: minScale 0 (the default) scales to zero, 1 keeps one warm; maxScale 1 by default. Never
# below 0, above maxScale, or a maxScale below 1.
agent=(-f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml")
must_render "${agent[@]}"
expect service 'autoscaling.knative.dev/min-scale: "0"'
expect service 'autoscaling.knative.dev/max-scale: "1"'
must_render "${agent[@]}" --set scale.agent.maxScale=3
expect service 'autoscaling.knative.dev/max-scale: "3"'
must_render "${agent[@]}" --set scale.agent.minScale=1
expect service 'autoscaling.knative.dev/min-scale: "1"'
must_render "${agent[@]}" --set scale.agent.minScale=3 --set scale.agent.maxScale=3
expect service 'autoscaling.knative.dev/min-scale: "3"'
must_fail "maxScale must be 1 or more" "${agent[@]}" --set scale.agent.maxScale=0
must_fail "minScale must be a whole number, 0 or more, not -1" "${agent[@]}" --set scale.agent.minScale=-1
must_fail "minScale must be a whole number, 0 or more, not 0.5" "${agent[@]}" --set scale.agent.minScale=0.5
must_fail "minScale must be at most scale.agent.maxScale (1), not 2" "${agent[@]}" --set scale.agent.minScale=2
must_fail "minScale must be at most scale.agent.maxScale (2), not 3" "${agent[@]}" --set scale.agent.maxScale=2 --set scale.agent.minScale=3

# Egress: anthropic reaches only the Anthropic API's addresses besides DNS, the proxy and the
# control plane.
must_render "${agent[@]}" -f "$tmp/egress.yaml"
expect policy '- Egress'
expect policy 'cidr: 160.79.104.0/23'
expect policy 'cidr: 2607:6bc0::/48'
expect policy 'cidr: 203.0.113.0/24'
expect policy 'port: 53'
expect policy 'app.kubernetes.io/name: operator-proxy'
expect_not policy '0.0.0.0/0'
# openai reaches the endpoint the values name, and not the Anthropic API.
must_render -f "$tmp/agent-base.yaml" -f "$tmp/openai.yaml" -f "$tmp/egress.yaml" -f "$tmp/gateway-egress.yaml" "${nostore[@]}"
expect policy 'cidr: 198.51.100.7/32'
expect_not policy '160.79.104.0/23'
# A proxy in front of the Anthropic API is reached through the model rules too.
must_render "${agent[@]}" -f "$tmp/egress.yaml" -f "$tmp/gateway-egress.yaml" --set scale.agent.model.baseURL=https://proxy.example.com
expect policy 'cidr: 198.51.100.7/32'
expect_not policy '160.79.104.0/23'

must_fail "egress needs controlPlaneCIDRs" "${agent[@]}" --set scale.agent.networkPolicy.egress.enabled=true
must_fail "egress needs model rules" -f "$tmp/agent-base.yaml" -f "$tmp/openai.yaml" -f "$tmp/egress.yaml" "${nostore[@]}"
must_fail "egress needs model rules" "${agent[@]}" -f "$tmp/egress.yaml" --set scale.agent.model.baseURL=https://proxy.example.com
must_fail "egress needs anthropicCIDRs" "${agent[@]}" -f "$tmp/egress.yaml" --set "scale.agent.networkPolicy.egress.anthropicCIDRs=null"
must_fail "egress.enabled needs scale.agent.networkPolicy.enabled" "${agent[@]}" -f "$tmp/egress.yaml" --set scale.agent.networkPolicy.enabled=false

# With a secret store, people set the model and key in the console (saved by the operator proxy as
# scale__<org>__agent-model), so neither provider needs a key or base URL here.
must_render -f "$tmp/agent-base.yaml" --set scale.agent.model.provider=anthropic
expect proxyconfig 'modelFromSecret: true'
expect_not service 'SCALE_AGENT_MODEL_API_KEY_FILE'
must_render -f "$tmp/agent-base.yaml" --set scale.agent.model.provider=openai
expect proxyconfig 'modelFromSecret: true'
# A key or gateway headers in the values decide, and the console's settings are not used.
must_render "${agent[@]}"
expect proxyconfig 'modelFromSecret: false'
expect service 'SCALE_AGENT_MODEL_API_KEY_FILE'
must_render -f "$tmp/agent-base.yaml" -f "$tmp/openai.yaml" --set scale.agent.model.headersSecret.name=gateway-headers
expect proxyconfig 'modelFromSecret: false'
# Without a secret store the console cannot save the settings.
must_render "${agent[@]}" "${nostore[@]}"
expect proxyconfig 'modelFromSecret: false'
# Egress with the console's settings allows the Anthropic API and the model rules, either of which
# people may pick, and needs at least one.
must_render -f "$tmp/agent-base.yaml" -f "$tmp/egress.yaml"
expect policy 'cidr: 160.79.104.0/23'
must_render -f "$tmp/agent-base.yaml" -f "$tmp/egress.yaml" -f "$tmp/gateway-egress.yaml"
expect policy 'cidr: 160.79.104.0/23'
expect policy 'cidr: 198.51.100.7/32'
must_fail "egress needs anthropicCIDRs or model rules" -f "$tmp/agent-base.yaml" -f "$tmp/egress.yaml" --set "scale.agent.networkPolicy.egress.anthropicCIDRs=null"

# "Keep Scale warm": the proxy prices one replica from the agent's requests, and minScale 1 or more
# wins over the console's setting.
must_render -f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml"
expect proxyconfig 'minScale: 0'
expect proxyconfig 'cpu: 100m'
expect proxyconfig 'memory: 512Mi'
must_render -f "$tmp/agent-base.yaml" -f "$tmp/anthropic.yaml" --set scale.agent.minScale=1
expect proxyconfig 'minScale: 1'

# With egress on and no model rules the agent reaches only the Anthropic API, so the proxy refuses
# any other endpoint people save in the console.
must_render -f "$tmp/agent-base.yaml" -f "$tmp/egress.yaml"
expect proxyconfig 'anthropicOnly: true'
must_render -f "$tmp/agent-base.yaml" -f "$tmp/egress.yaml" -f "$tmp/gateway-egress.yaml"
expect proxyconfig 'anthropicOnly: false'
must_render -f "$tmp/agent-base.yaml"
expect proxyconfig 'anthropicOnly: false'

if [ "$failures" -gt 0 ]; then echo "$failures Scale guard check(s) failed"; exit 1; fi
echo "Scale guards OK"
