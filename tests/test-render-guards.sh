#!/usr/bin/env bash

# Must-fail tests for the render-time guards in templates/common/validation.yaml.
#
# tests/run.sh only compares successful renders against golden files, so a `fail`
# that stops firing is invisible to it: the guarded values combination simply has
# no snapshot. This script asserts the opposite direction — helm exits non-zero
# and says why.

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CHART="${SCRIPT_DIR}/../charts/dataplane"

BASE=(
  --namespace union
  --kube-version 1.32.0
  --values "${CHART}/examples/values-test-certs.yaml"
  --set host=test.example.com
  --set secrets.admin.clientId=test-client-id
  --set secrets.admin.clientSecret=test-client-secret
)

failures=0

# expect-fail <description> <expected substring> [extra helm args...]
function expect-fail {
  local desc=$1 expected=$2
  shift 2
  local output
  if output=$(helm template "${CHART}" "${BASE[@]}" "$@" 2>&1); then
    echo "FAIL: ${desc}: render succeeded, expected it to fail"
    failures=$((failures + 1))
    return
  fi
  if [[ ${output} != *"${expected}"* ]]; then
    echo "FAIL: ${desc}: render failed but the message did not mention '${expected}'"
    echo "${output}" | tail -3
    failures=$((failures + 1))
    return
  fi
  echo "ok: ${desc}"
}

# expect-render <description> [extra helm args...]
function expect-render {
  local desc=$1
  shift
  local output
  if ! output=$(helm template "${CHART}" "${BASE[@]}" "$@" 2>&1); then
    echo "FAIL: ${desc}: render failed, expected it to succeed"
    echo "${output}" | tail -3
    failures=$((failures + 1))
    return
  fi
  echo "ok: ${desc}"
}

expect-fail "clusterresourcesync at the default single-namespace posture" \
  "namespaces.enabled: true" \
  --set clusterresourcesync.enabled=true

expect-fail "clusterresourcesync with a truthy low_privilege overriding namespaces.enabled" \
  "namespaces.enabled: true" \
  --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true \
  --set low_privilege=true

# The pre-existing incoherent cell: reads as full privilege, resolves to single
# namespace. Silent on main; a render error now.
expect-fail "clusterresourcesync with low_privilege: false and namespaces.enabled: false" \
  "namespaces.enabled: true" \
  --set clusterresourcesync.enabled=true \
  --set low_privilege=false

expect-fail "release namespace listed in namespaces.static" \
  "must not contain the release namespace" \
  --set namespaces.enabled=true \
  --set 'namespaces.static={union}'

expect-render "clusterresourcesync in the multi-namespace posture" \
  --set clusterresourcesync.enabled=true \
  --set namespaces.enabled=true

expect-render "release namespace in namespaces.static is not checked when the posture is single" \
  --set 'namespaces.static={union}'

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} render guard test(s) failed"
  exit 1
fi

echo "render guard tests passed"
