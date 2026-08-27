#!/usr/bin/env bash
# Create a Buildkite build on a cloud pipeline via the REST API.
#
# Usage: trigger-buildkite-build.sh <pipeline-slug> [KEY=VALUE ...]
#
# Each KEY=VALUE becomes a build env var. TRIGGER_PROVENANCE is always added,
# stamped as "helm-charts@<sha> by <actor>" so the triggered cloud pipeline
# (and its PR-back / annotation) can attribute the run to this merge.
#
# The build runs cloud's main (commit HEAD, branch main): the target pipelines'
# repository is unionai/cloud, so they must build cloud, not helm-charts.
#
# Requires: BUILDKITE_API_TOKEN in the environment (Buildkite API token with the
# write_builds scope), plus GITHUB_SHA and GITHUB_ACTOR (set by Actions).
set -euo pipefail

pipeline="${1:?pipeline slug required}"
shift || true

org="unionai"
provenance="helm-charts@${GITHUB_SHA} by ${GITHUB_ACTOR}"

# Build the env object from the KEY=VALUE args plus provenance.
env_json='{}'
for kv in "$@"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  env_json="$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$env_json")"
done
env_json="$(jq -c --arg v "$provenance" '. + {TRIGGER_PROVENANCE: $v}' <<<"$env_json")"

body="$(jq -n \
  --arg commit "HEAD" \
  --arg branch "main" \
  --arg message "$provenance: trigger ${pipeline}" \
  --argjson env "$env_json" \
  '{commit: $commit, branch: $branch, message: $message, env: $env}')"

echo "Triggering ${org}/${pipeline} with env: ${env_json}"
curl --fail --silent --show-error \
  -X POST \
  -H "Authorization: Bearer ${BUILDKITE_API_TOKEN}" \
  "https://api.buildkite.com/v2/organizations/${org}/pipelines/${pipeline}/builds" \
  -d "$body" \
  | jq -r '"Created build: \(.web_url)"'
