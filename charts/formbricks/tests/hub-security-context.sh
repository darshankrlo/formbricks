#!/usr/bin/env bash

# Hub containers must render hub.containerSecurityContext (UID 1000) and the Node-based migration
# containers must render migration.containerSecurityContext (UID 1001). Both default to
# restricted-compatible values, are overridable independently, and the Node defaults keep a writable
# root filesystem so older migration images keep working.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CHART_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

render() {
  local template="$1"
  shift
  helm template qa "${CHART_DIR}" \
    --set formbricks.webappUrl=https://qa.example.com \
    --show-only "templates/${template}" \
    ${@+"$@"}
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

# Hub containers: $1 template, $2 expected block count, rest: extra helm args (to scope the render).
check_hub() {
  local template="$1" blocks="$2" contexts
  shift 2

  contexts="$(container_contexts "$(render "${template}" ${@+"$@"})")"
  expect_count "${contexts}" 'BLOCK' "${blocks}" "${template} Hub container blocks"
  expect_count "${contexts}" '            allowPrivilegeEscalation: false' "${blocks}" "${template} Hub defaults"
  expect_count "${contexts}" '            readOnlyRootFilesystem: true' "${blocks}" "${template} Hub defaults"
  expect_count "${contexts}" '            runAsNonRoot: true' "${blocks}" "${template} Hub defaults"
  expect_count "${contexts}" '            runAsUser: 1000' "${blocks}" "${template} Hub defaults"
  expect_count "${contexts}" '              - ALL' "${blocks}" "${template} Hub defaults"
  expect_count "${contexts}" '              type: RuntimeDefault' "${blocks}" "${template} Hub defaults"

  contexts="$(container_contexts "$(render "${template}" ${@+"$@"} \
    --set hub.containerSecurityContext.allowPrivilegeEscalation=true \
    --set 'hub.containerSecurityContext.capabilities.drop[0]=NET_RAW' \
    --set hub.containerSecurityContext.runAsUser=2000 \
    --set deployment.containerSecurityContext.runAsUser=3000 \
    --set migration.containerSecurityContext.runAsUser=4000)")"
  expect_count "${contexts}" '            allowPrivilegeEscalation: true' "${blocks}" "${template} Hub overrides"
  expect_count "${contexts}" '            allowPrivilegeEscalation: false' 0 "${template} Hub overrides"
  expect_count "${contexts}" '              - NET_RAW' "${blocks}" "${template} Hub overrides"
  expect_count "${contexts}" '              - ALL' 0 "${template} Hub overrides"
  expect_count "${contexts}" '            runAsUser: 2000' "${blocks}" "${template} Hub overrides"
  expect_count "${contexts}" '            runAsUser: 3000' 0 "${template} Hub must ignore deployment.containerSecurityContext"
  expect_count "${contexts}" '            runAsUser: 4000' 0 "${template} Hub must ignore migration.containerSecurityContext"
}

# Hub API Deployment (hub-migrate + hub) and worker Deployment (wait-for-hub-api + hub-worker).
# The Node-based wait container is switched off here so only Hub containers are counted.
check_hub hub-deployment.yaml 2 --set migration.enabled=false
check_hub hub-worker-deployment.yaml 2
# Hub migration Job (hub-migrate).
check_hub hub-migration-job.yaml 1

# Node migration Job (wait-for-database + migration), UID 1001, writable root filesystem.
contexts="$(container_contexts "$(render migration-job.yaml)")"
expect_count "${contexts}" 'BLOCK' 2 "Node migration Job blocks"
expect_count "${contexts}" '            allowPrivilegeEscalation: false' 2 "Node migration Job defaults"
expect_count "${contexts}" '            runAsNonRoot: true' 2 "Node migration Job defaults"
expect_count "${contexts}" '            runAsUser: 1001' 2 "Node migration Job defaults"
expect_count "${contexts}" '              - ALL' 2 "Node migration Job defaults"
expect_count "${contexts}" '              type: RuntimeDefault' 2 "Node migration Job defaults"
expect_count "${contexts}" '            readOnlyRootFilesystem: true' 0 "Node migration Job must keep a writable root"

contexts="$(container_contexts "$(render migration-job.yaml \
  --set migration.containerSecurityContext.allowPrivilegeEscalation=true \
  --set 'migration.containerSecurityContext.capabilities.drop[0]=NET_RAW' \
  --set migration.containerSecurityContext.runAsUser=4000 \
  --set hub.containerSecurityContext.runAsUser=2000 \
  --set deployment.containerSecurityContext.runAsUser=3000)")"
expect_count "${contexts}" '            allowPrivilegeEscalation: true' 2 "Node migration Job overrides"
expect_count "${contexts}" '            allowPrivilegeEscalation: false' 0 "Node migration Job overrides"
expect_count "${contexts}" '              - NET_RAW' 2 "Node migration Job overrides"
expect_count "${contexts}" '              - ALL' 0 "Node migration Job overrides"
expect_count "${contexts}" '            runAsUser: 4000' 2 "Node migration Job overrides"
expect_count "${contexts}" '            runAsUser: 2000' 0 "Node migration Job must ignore hub.containerSecurityContext"
expect_count "${contexts}" '            runAsUser: 3000' 0 "Node migration Job must ignore deployment.containerSecurityContext"

# wait-for-formbricks-migration init container in the Hub Deployment: Node UID next to two Hub containers.
contexts="$(container_contexts "$(render hub-deployment.yaml)")"
expect_count "${contexts}" 'BLOCK' 3 "Hub Deployment blocks with the Node wait container"
expect_count "${contexts}" '            runAsUser: 1001' 1 "Hub Deployment Node wait container default"
expect_count "${contexts}" '            runAsUser: 1000' 2 "Hub Deployment Hub containers default"
expect_count "${contexts}" '            readOnlyRootFilesystem: true' 2 "Only the Hub containers use a read-only root"

contexts="$(container_contexts "$(render hub-deployment.yaml \
  --set migration.containerSecurityContext.runAsUser=4000 \
  --set hub.containerSecurityContext.runAsUser=2000)")"
expect_count "${contexts}" '            runAsUser: 4000' 1 "Hub Deployment Node wait container override"
expect_count "${contexts}" '            runAsUser: 2000' 2 "Hub Deployment Hub containers override"
expect_count "${contexts}" '            runAsUser: 1001' 0 "Hub Deployment Node wait container override"
