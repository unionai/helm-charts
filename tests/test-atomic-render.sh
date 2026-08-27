#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/lib/atomic-render.sh"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/helm-charts-atomic-render.XXXXXX")
trap 'rm -rf "${TEST_DIR}"' EXIT
TARGET="${TEST_DIR}/snapshot.yaml"

function fail-after-partial-output {
  printf 'partial output\n'
  return 42
}

function render-complete-output {
  printf 'complete output\n'
}

printf 'existing snapshot\n' > "${TARGET}"

if render-atomically "${TARGET}" fail-after-partial-output; then
  echo "expected the failing render to return non-zero"
  exit 1
else
  status=$?
fi

if [[ ${status} -ne 42 ]]; then
  echo "expected render exit status 42, got ${status}"
  exit 1
fi

if [[ $(<"${TARGET}") != "existing snapshot" ]]; then
  echo "failing render changed the existing snapshot"
  exit 1
fi

if compgen -G "${TARGET}.tmp.*" > /dev/null; then
  echo "failing render left a temporary file"
  exit 1
fi

render-atomically "${TARGET}" render-complete-output

if [[ $(<"${TARGET}") != "complete output" ]]; then
  echo "successful render did not replace the snapshot"
  exit 1
fi

echo "atomic render tests passed"
