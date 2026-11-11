#!/usr/bin/env bash

# Hub containers (API, hub-migrate, hub-worker, wait-for-hub-api) must render hub.containerSecurityContext
# with restricted-compatible defaults, and operators must be able to override it independently of the
# web container's deployment.containerSecurityContext.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CHART_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

render() {
  local template="$1"
  shift
  helm template qa "${CHART_DIR}" \
    --set formbricks.webappUrl=https://qa.example.com \
    --show-only "templates/${template}" \
    "$@"
}

# Prints every container-level securityContext block (10-space indented), one "BLOCK" marker per block.
container_contexts() {
  awk '
    /^          securityContext:$/ { inside = 1; print "BLOCK"; next }
    inside && /^            / { print; next }
    inside { inside = 0 }
  ' <<<"$1"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

expect_count() {
  local haystack="$1" line="$2" expected="$3" message="$4" actual
  actual="$(grep -cxF -- "${line}" <<<"${haystack}" || true)"
  [[ "${actual}" -eq "${expected}" ]] || fail "${message}: expected ${expected} x '${line}', found ${actual}"
}

check_defaults() {
  local template="$1" blocks="$2" contexts
  contexts="$(container_contexts "$(render "${template}")")"
  expect_count "${contexts}" 'BLOCK' "${blocks}" "${template} container securityContext blocks"
  expect_count "${contexts}" '            allowPrivilegeEscalation: false' "${blocks}" "${template} defaults"
  expect_count "${contexts}" '            readOnlyRootFilesystem: true' "${blocks}" "${template} defaults"
  expect_count "${contexts}" '            runAsNonRoot: true' "${blocks}" "${template} defaults"
  expect_count "${contexts}" '            runAsUser: 1000' "${blocks}" "${template} defaults"
  expect_count "${contexts}" '              - ALL' "${blocks}" "${template} defaults"
  expect_count "${contexts}" '              type: RuntimeDefault' "${blocks}" "${template} defaults"
}

check_overrides() {
  local template="$1" blocks="$2" contexts
  contexts="$(container_contexts "$(render "${template}" \
    --set hub.containerSecurityContext.allowPrivilegeEscalation=true \
    --set 'hub.containerSecurityContext.capabilities.drop[0]=NET_RAW' \
    --set hub.containerSecurityContext.runAsUser=2000 \
    --set deployment.containerSecurityContext.runAsUser=3000)")"
  expect_count "${contexts}" '            allowPrivilegeEscalation: true' "${blocks}" "${template} overrides"
  expect_count "${contexts}" '            allowPrivilegeEscalation: false' 0 "${template} overrides"
  expect_count "${contexts}" '              - NET_RAW' "${blocks}" "${template} overrides"
  expect_count "${contexts}" '              - ALL' 0 "${template} overrides"
  expect_count "${contexts}" '            runAsUser: 2000' "${blocks}" "${template} overrides"
  # The web container's context must not leak into Hub.
  expect_count "${contexts}" '            runAsUser: 3000' 0 "${template} must ignore deployment.containerSecurityContext"
}

# Hub API Deployment: hub-migrate init container + hub container.
check_defaults hub-deployment.yaml 2
check_overrides hub-deployment.yaml 2

# Hub worker Deployment: wait-for-hub-api init container + hub-worker container.
check_defaults hub-worker-deployment.yaml 2
check_overrides hub-worker-deployment.yaml 2
