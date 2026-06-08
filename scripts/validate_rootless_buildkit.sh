#!/usr/bin/env bash

set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
NAMESPACE="${NAMESPACE:-union}"
DEPLOYMENT="${DEPLOYMENT:-union-operator-buildkit}"
CONTAINER="${CONTAINER:-buildkit}"
SERVICE="${SERVICE:-union-operator-buildkit}"
PORT="${PORT:-1234}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"
TARGET_IMAGE="${TARGET_IMAGE:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

jsonpath() {
  local resource=$1
  local path=$2
  "${KUBECTL_BIN}" -n "${NAMESPACE}" get "${resource}" -o "jsonpath=${path}"
}

require_contains() {
  local value=$1
  local expected=$2
  local label=$3

  if [[ "${value}" != *"${expected}"* ]]; then
    die "${label} must contain ${expected}; got: ${value}"
  fi
}

require_not_contains() {
  local value=$1
  local unexpected=$2
  local label=$3

  if [[ "${value}" == *"${unexpected}"* ]]; then
    die "${label} must not contain ${unexpected}; got: ${value}"
  fi
}

if ! command -v "${KUBECTL_BIN}" >/dev/null 2>&1; then
  die "KUBECTL_BIN=${KUBECTL_BIN} is not on PATH"
fi

info "Checking deployment rollout"
"${KUBECTL_BIN}" -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout="${ROLLOUT_TIMEOUT}"

info "Checking service endpoint"
service_port="$(jsonpath "service/${SERVICE}" '{.spec.ports[?(@.name=="tcp")].port}')"
[[ "${service_port}" == "${PORT}" ]] || die "service ${SERVICE} tcp port must be ${PORT}; got: ${service_port}"

info "Checking rootless deployment shape"
image="$(jsonpath "deployment/${DEPLOYMENT}" "{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].image}")"
args="$(jsonpath "deployment/${DEPLOYMENT}" "{range .spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].args[*]}{.}{\"\\n\"}{end}")"
run_as_user="$(jsonpath "deployment/${DEPLOYMENT}" "{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].securityContext.runAsUser}")"
run_as_group="$(jsonpath "deployment/${DEPLOYMENT}" "{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].securityContext.runAsGroup}")"
seccomp_type="$(jsonpath "deployment/${DEPLOYMENT}" "{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].securityContext.seccompProfile.type}")"
privileged="$(jsonpath "deployment/${DEPLOYMENT}" "{.spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].securityContext.privileged}")"
annotations="$(jsonpath "deployment/${DEPLOYMENT}" '{.spec.template.metadata.annotations}')"
mounts="$(jsonpath "deployment/${DEPLOYMENT}" "{range .spec.template.spec.containers[?(@.name==\"${CONTAINER}\")].volumeMounts[*]}{.mountPath}{\"\\n\"}{end}")"

require_contains "${image}" "rootless" "BuildKit image"
require_contains "${args}" "unix:///run/user/1000/buildkit/buildkitd.sock" "BuildKit args"
require_contains "${args}" "--oci-worker-no-process-sandbox" "BuildKit args"
[[ "${run_as_user}" == "1000" ]] || die "BuildKit runAsUser must be 1000; got: ${run_as_user}"
[[ "${run_as_group}" == "1000" ]] || die "BuildKit runAsGroup must be 1000; got: ${run_as_group}"
[[ "${seccomp_type}" == "Unconfined" ]] || die "BuildKit seccompProfile.type must be Unconfined; got: ${seccomp_type}"
[[ "${privileged}" != "true" ]] || die "BuildKit securityContext must not set privileged=true"
require_contains "${annotations}" "container.apparmor.security.beta.kubernetes.io/buildkit:unconfined" "pod annotations"
require_contains "${mounts}" "/home/user/.local/share/buildkit" "BuildKit volume mounts"

pod="$("${KUBECTL_BIN}" -n "${NAMESPACE}" get pod \
  -l app.kubernetes.io/name=imagebuilder-buildkit \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${pod}" ]] || die "no BuildKit pod found in namespace ${NAMESPACE}"

info "Checking BuildKit workers in pod ${pod}"
"${KUBECTL_BIN}" -n "${NAMESPACE}" exec "${pod}" -c "${CONTAINER}" -- \
  buildctl --addr "tcp://127.0.0.1:${PORT}" debug workers

if [[ -n "${TARGET_IMAGE}" ]]; then
  info "Running build-and-push smoke test to ${TARGET_IMAGE}"
  "${KUBECTL_BIN}" -n "${NAMESPACE}" exec "${pod}" -c "${CONTAINER}" -- sh -ec '
    port="$1"
    target_image="$2"
    tmp="$(mktemp -d)"
    trap "rm -rf ${tmp}" EXIT

    cat >"${tmp}/Dockerfile" <<EOF
FROM scratch
COPY rootless-buildkit-smoke.txt /rootless-buildkit-smoke.txt
EOF
    echo rootless-buildkit-smoke > "${tmp}/rootless-buildkit-smoke.txt"

    buildctl --addr "tcp://127.0.0.1:${port}" build \
      --frontend dockerfile.v0 \
      --local "context=${tmp}" \
      --local "dockerfile=${tmp}" \
      --output "type=image,name=${target_image},push=true"
  ' sh "${PORT}" "${TARGET_IMAGE}"
else
  info "Skipping build-and-push smoke test because TARGET_IMAGE is unset"
fi

info "Rootless BuildKit validation completed"
