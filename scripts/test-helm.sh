#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Helm chart contract tests for Iskaar.
# Validates: Requirements 3.5, 5.5, 6.3, 7.8, 7.9
#
# This script only invokes helm lint/template. It never contacts or mutates a
# Kubernetes cluster and never prints rendered manifests or secret values.
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${PROJECT_DIR}/helm/iskaar"
SCHEMA_FILE="${CHART_DIR}/values.schema.json"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
HELM_BIN="${HELM_BIN:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        ${YELLOW}Detail: $2${NC}"
    fi
}

section() {
    echo ""
    echo "--- $1 ---"
}

values_file_for() {
    local environment="$1"
    printf '%s/values-%s.yaml' "${CHART_DIR}" "${environment}"
}

registry_for() {
    case "$1" in
        dev|stage)
            printf '%s' 'localhost:5000'
            ;;
        prod)
            printf '%s' 'registry.example.com'
            ;;
        *)
            return 1
            ;;
    esac
}

pull_policy_for() {
    case "$1" in
        dev|stage)
            printf '%s' 'IfNotPresent'
            ;;
        prod)
            printf '%s' 'Always'
            ;;
        *)
            return 1
            ;;
    esac
}

# Keep Helm output in the caller's variable. Do not print it: a rendered
# manifest can contain credential material when a caller supplies custom data.
run_helm_lint() {
    local environment="$1"
    shift
    "${HELM_BIN}" lint "${CHART_DIR}" \
        -f "$(values_file_for "${environment}")" \
        "$@" >/dev/null 2>&1
}

render_chart() {
    local environment="$1"
    shift
    "${HELM_BIN}" template iskaar "${CHART_DIR}" \
        -f "$(values_file_for "${environment}")" \
        "$@" 2>/dev/null
}

count_kind() {
    local wanted_kind="$1"
    awk -v wanted_kind="${wanted_kind}" '$1 == "kind:" && $2 == wanted_kind { count++ } END { print count + 0 }'
}

count_resource_name() {
    local wanted_name="$1"
    awk -v wanted_name="${wanted_name}" '
        /^  name: / {
            name = $0
            sub(/^  name: /, "", name)
            if (name == wanted_name) {
                count++
            }
        }
        END { print count + 0 }
    '
}

assert_kind_count() {
    local description="$1"
    local rendered="$2"
    local kind="$3"
    local expected="$4"
    local actual
    actual=$(printf '%s\n' "${rendered}" | count_kind "${kind}")

    if [[ "${actual}" == "${expected}" ]]; then
        pass "${description} (${actual})"
    else
        fail "${description}" "expected ${expected} ${kind} resource(s), found ${actual}"
    fi
}

assert_resource_total() {
    local description="$1"
    local rendered="$2"
    local expected="$3"
    local actual
    actual=$(printf '%s\n' "${rendered}" | awk '$1 == "kind:" { count++ } END { print count + 0 }')

    if [[ "${actual}" == "${expected}" ]]; then
        pass "${description} (${actual} resources)"
    else
        fail "${description}" "expected ${expected} resources, found ${actual}"
    fi
}

assert_resource_name_count() {
    local description="$1"
    local rendered="$2"
    local name="$3"
    local expected="$4"
    local actual
    actual=$(printf '%s\n' "${rendered}" | count_resource_name "${name}")

    if [[ "${actual}" == "${expected}" ]]; then
        pass "${description} (${actual})"
    else
        fail "${description}" "expected ${expected} resource(s) named ${name}, found ${actual}"
    fi
}

assert_render_contains() {
    local description="$1"
    local rendered="$2"
    local needle="$3"

    if grep -Fq -- "${needle}" <<<"${rendered}"; then
        pass "${description}"
    else
        fail "${description}" "expected contract marker was not rendered"
    fi
}

assert_render_excludes() {
    local description="$1"
    local rendered="$2"
    local needle="$3"

    if grep -Fq -- "${needle}" <<<"${rendered}"; then
        fail "${description}" "forbidden contract marker was rendered"
    else
        pass "${description}"
    fi
}

# --- Schema and flag tests ---------------------------------------------------

test_schema_contract() {
    section "Values Schema Contract"

    if [[ -s "${SCHEMA_FILE}" ]]; then
        pass "values.schema.json is present"
    else
        fail "values.schema.json is present" "missing or empty schema at ${SCHEMA_FILE}"
        return
    fi

    local boolean_fields
    boolean_fields=$(grep -c '"type": "boolean"' "${SCHEMA_FILE}" || true)
    if [[ "${boolean_fields}" -ge 8 ]]; then
        pass "Schema declares typed boolean fields (found ${boolean_fields})"
    else
        fail "Schema declares typed boolean fields" "expected at least 8 boolean declarations, found ${boolean_fields}"
    fi

    local environment
    for environment in dev stage prod; do
        if run_helm_lint "${environment}"; then
            pass "Schema validates default ${environment} values"
        else
            fail "Schema validates default ${environment} values" "helm lint failed for values-${environment}.yaml"
        fi
    done

    # The chart contract intentionally uses monitoring.enabled. A scalar
    # --set monitoring=false must fail schema validation rather than silently
    # replacing the monitoring object.
    if run_helm_lint dev --set monitoring=false; then
        fail "Schema rejects scalar --set monitoring=false" "monitoring must remain an object with enabled"
    else
        pass "Schema rejects scalar --set monitoring=false"
    fi
}

test_flag_matrix() {
    section "Deploy and Monitoring Flag Matrix"

    local environment value
    for environment in dev stage prod; do
        for value in false true; do
            if run_helm_lint "${environment}" --set "deploy=${value}"; then
                pass "helm lint ${environment} with --set deploy=${value}"
            else
                fail "helm lint ${environment} with --set deploy=${value}" "schema or chart lint failed"
            fi

            if render_chart "${environment}" --set "deploy=${value}" >/dev/null; then
                pass "helm template ${environment} with --set deploy=${value}"
            else
                fail "helm template ${environment} with --set deploy=${value}" "render failed"
            fi
        done

        # monitoring is an object in the chart schema; this is the typed
        # equivalent of the public monitoring=false/true mode values.
        for value in false true; do
            if run_helm_lint "${environment}" --set "monitoring.enabled=${value}"; then
                pass "helm lint ${environment} with --set monitoring.enabled=${value}"
            else
                fail "helm lint ${environment} with --set monitoring.enabled=${value}" "schema or chart lint failed"
            fi

            if render_chart "${environment}" --set "monitoring.enabled=${value}" >/dev/null; then
                pass "helm template ${environment} with --set monitoring.enabled=${value}"
            else
                fail "helm template ${environment} with --set monitoring.enabled=${value}" "render failed"
            fi
        done

        if run_helm_lint "${environment}" --set deploy=true --set monitoring.enabled=true; then
            pass "helm lint ${environment} with deploy=true and monitoring.enabled=true"
        else
            fail "helm lint ${environment} with deploy=true and monitoring.enabled=true" "combined flag render failed"
        fi

        if render_chart "${environment}" --set deploy=true --set monitoring.enabled=true >/dev/null; then
            pass "helm template ${environment} with deploy=true and monitoring.enabled=true"
        else
            fail "helm template ${environment} with deploy=true and monitoring.enabled=true" "combined flag render failed"
        fi
    done

    if run_helm_lint dev --set deploy=invalid; then
        fail "Schema rejects invalid deploy value" "non-boolean deploy value was accepted"
    else
        pass "Schema rejects invalid deploy value"
    fi

    if run_helm_lint dev --set monitoring.enabled=invalid; then
        fail "Schema rejects invalid monitoring value" "non-boolean monitoring value was accepted"
    else
        pass "Schema rejects invalid monitoring value"
    fi
}

# --- Existing environment/template tests -----------------------------------

test_chart_lint() {
    section "Chart Lint"
    local environment
    for environment in dev stage prod; do
        if run_helm_lint "${environment}"; then
            pass "Chart lint passes for ${environment}"
        else
            fail "Chart lint passes for ${environment}" "helm lint reported errors"
        fi
    done
}

test_dev_template_renders() {
    section "Dev Template Rendering"
    local output
    if output=$(render_chart dev); then
        pass "Dev template renders successfully"
    else
        fail "Dev template renders successfully" "helm template failed for values-dev.yaml"
        return
    fi

    assert_render_contains "Dev uses registry prefix (localhost:5000/iskaar-backend)" "${output}" "image: \"localhost:5000/iskaar-backend:latest\""
    assert_render_contains "Dev uses registry prefix (localhost:5000/iskaar-frontend)" "${output}" "image: \"localhost:5000/iskaar-frontend:latest\""
}

test_stage_template_renders() {
    section "Stage Template Rendering"
    local output
    if output=$(render_chart stage); then
        pass "Stage template renders successfully"
    else
        fail "Stage template renders successfully" "helm template failed for values-stage.yaml"
        return
    fi

    assert_render_contains "Stage has resource requests" "${output}" "requests:"
    assert_render_contains "Stage has resource limits" "${output}" "limits:"
}

test_prod_template_renders() {
    section "Prod Template Rendering"
    local output
    if output=$(render_chart prod); then
        pass "Prod template renders successfully"
    else
        fail "Prod template renders successfully" "helm template failed for values-prod.yaml"
        return
    fi

    local backend_replicas frontend_replicas
    backend_replicas=$(awk '
        /^kind: Deployment$/ { in_deployment=1; target="" }
        /^  name: iskaar-backend$/ && in_deployment { target="backend" }
        target == "backend" && /^  replicas: / { print $2; exit }
        /^---$/ && in_deployment { in_deployment=0 }
    ' <<<"${output}")
    frontend_replicas=$(awk '
        /^kind: Deployment$/ { in_deployment=1; target="" }
        /^  name: iskaar-frontend$/ && in_deployment { target="frontend" }
        target == "frontend" && /^  replicas: / { print $2; exit }
        /^---$/ && in_deployment { in_deployment=0 }
    ' <<<"${output}")

    if [[ "${backend_replicas:-0}" -ge 2 ]] 2>/dev/null; then
        pass "Prod backend has at least two replicas (${backend_replicas})"
    else
        fail "Prod backend has at least two replicas" "replica count was ${backend_replicas:-not found}"
    fi

    if [[ "${frontend_replicas:-0}" -ge 2 ]] 2>/dev/null; then
        pass "Prod frontend has at least two replicas (${frontend_replicas})"
    else
        fail "Prod frontend has at least two replicas" "replica count was ${frontend_replicas:-not found}"
    fi
}

test_no_latest_tags() {
    section "No :latest Tags with Explicit Tags"
    local output
    if output=$(render_chart dev \
        --set-string image.backend.tag=v1.0.0 \
        --set-string image.frontend.tag=v1.0.0); then
        if grep -Fq ':latest' <<<"${output}"; then
            fail "No :latest tags when explicit tag is set" "a latest tag was rendered"
        else
            pass "No :latest tags when explicit tag is set"
        fi
    else
        fail "No :latest tags when explicit tag is set" "render failed"
    fi
}

test_tag_injection() {
    section "Tag Injection"
    local output
    if ! output=$(render_chart dev \
        --set-string image.backend.tag=v1.0.0 \
        --set-string image.frontend.tag=v1.0.0); then
        fail "Tag injection render succeeds" "render failed"
        return
    fi

    assert_render_contains "Backend tag injection works" "${output}" "image: \"localhost:5000/iskaar-backend:v1.0.0\""
    assert_render_contains "Frontend tag injection works" "${output}" "image: \"localhost:5000/iskaar-frontend:v1.0.0\""
}

test_registry_prefix_consistency() {
    section "Registry and Image-Pull-Policy Consistency"

    local environment registry pull_policy output
    for environment in dev stage prod; do
        registry=$(registry_for "${environment}")
        pull_policy=$(pull_policy_for "${environment}")
        if ! output=$(render_chart "${environment}" \
            --set-string image.backend.tag=contract-test \
            --set-string image.frontend.tag=contract-test); then
            fail "${environment} image contract renders"
            continue
        fi

        assert_render_contains "${environment} backend image reference is ${registry}" "${output}" "image: \"${registry}/iskaar-backend:contract-test\""
        assert_render_contains "${environment} frontend image reference is ${registry}" "${output}" "image: \"${registry}/iskaar-frontend:contract-test\""
        assert_render_contains "${environment} imagePullPolicy is ${pull_policy}" "${output}" "imagePullPolicy: ${pull_policy}"
    done
}

# --- Secret and phase tests --------------------------------------------------

test_secret_references() {
    section "Secret References"

    local output local_output secret_refs local_secret_refs
    if ! output=$(render_chart dev); then
        fail "Default secret reference render succeeds" "render failed"
        return
    fi

    assert_kind_count "Default render contains one placeholder Secret" "${output}" Secret 1
    secret_refs=$(grep -Fc 'secretKeyRef:' <<<"${output}" || true)
    if [[ "${secret_refs}" == 5 ]]; then
        pass "Default database and backend references use secretKeyRef (5)"
    else
        fail "Default database and backend references use secretKeyRef" "expected 5 references, found ${secret_refs}"
    fi
    assert_render_contains "Default references use postgres-credentials" "${output}" "name: postgres-credentials"

    if ! local_output=$(render_chart dev \
        --set postgresql.createPlaceholderSecret=false \
        --set postgresql.existingSecret=postgres-credentials); then
        fail "Local-Secret render succeeds" "render failed"
        return
    fi

    assert_kind_count "Local-Secret render contains no Secret resource" "${local_output}" Secret 0
    assert_render_excludes "Local-Secret render omits placeholder data" "${local_output}" "aXNrYWFy"
    local_secret_refs=$(grep -Fc 'name: postgres-credentials' <<<"${local_output}" || true)
    if [[ "${local_secret_refs}" == 5 ]]; then
        pass "Local-Secret references use postgres-credentials (5 references)"
    else
        fail "Local-Secret references use postgres-credentials" "expected 5 references, found ${local_secret_refs}"
    fi
}

check_phase() {
    local phase="$1"
    local expected_total="$2"
    shift 2
    local -a component_flags=("$@")
    local output

    if ! output=$(render_chart dev \
        --set deploy=false \
        --set monitoring.enabled=false \
        "${component_flags[@]}"); then
        fail "${phase} phase renders"
        return
    fi

    pass "${phase} phase renders"
    assert_resource_total "${phase} phase resource count" "${output}" "${expected_total}"
    assert_kind_count "${phase} Namespace count" "${output}" Namespace 1

    case "${phase}" in
        Namespace)
            assert_kind_count "${phase} Secret count" "${output}" Secret 0
            assert_kind_count "${phase} PVC count" "${output}" PersistentVolumeClaim 0
            assert_kind_count "${phase} Deployment count" "${output}" Deployment 0
            assert_kind_count "${phase} Service count" "${output}" Service 0
            assert_kind_count "${phase} ClusterIssuer count" "${output}" ClusterIssuer 0
            assert_kind_count "${phase} Ingress count" "${output}" Ingress 0
            assert_resource_name_count "${phase} namespace resource" "${output}" iskaar 1
            ;;
        Database)
            assert_kind_count "${phase} Secret count" "${output}" Secret 1
            assert_kind_count "${phase} PVC count" "${output}" PersistentVolumeClaim 1
            assert_kind_count "${phase} Deployment count" "${output}" Deployment 1
            assert_kind_count "${phase} Service count" "${output}" Service 1
            assert_kind_count "${phase} ClusterIssuer count" "${output}" ClusterIssuer 0
            assert_kind_count "${phase} Ingress count" "${output}" Ingress 0
            assert_resource_name_count "${phase} namespace resource" "${output}" iskaar 1
            assert_resource_name_count "${phase} placeholder Secret" "${output}" postgres-credentials 1
            assert_resource_name_count "${phase} PVC" "${output}" postgres-data 1
            assert_resource_name_count "${phase} PostgreSQL resources" "${output}" postgresql 2
            ;;
        Backend)
            assert_kind_count "${phase} Secret count" "${output}" Secret 1
            assert_kind_count "${phase} PVC count" "${output}" PersistentVolumeClaim 1
            assert_kind_count "${phase} Deployment count" "${output}" Deployment 2
            assert_kind_count "${phase} Service count" "${output}" Service 2
            assert_kind_count "${phase} ClusterIssuer count" "${output}" ClusterIssuer 0
            assert_kind_count "${phase} Ingress count" "${output}" Ingress 0
            assert_resource_name_count "${phase} backend resources" "${output}" iskaar-backend 2
            ;;
        Frontend)
            assert_kind_count "${phase} Secret count" "${output}" Secret 1
            assert_kind_count "${phase} PVC count" "${output}" PersistentVolumeClaim 1
            assert_kind_count "${phase} Deployment count" "${output}" Deployment 3
            assert_kind_count "${phase} Service count" "${output}" Service 3
            assert_kind_count "${phase} ClusterIssuer count" "${output}" ClusterIssuer 0
            assert_kind_count "${phase} Ingress count" "${output}" Ingress 0
            assert_resource_name_count "${phase} frontend resources" "${output}" iskaar-frontend 2
            ;;
        TLS)
            assert_kind_count "${phase} Secret count" "${output}" Secret 1
            assert_kind_count "${phase} PVC count" "${output}" PersistentVolumeClaim 1
            assert_kind_count "${phase} Deployment count" "${output}" Deployment 3
            assert_kind_count "${phase} Service count" "${output}" Service 3
            assert_kind_count "${phase} ClusterIssuer count" "${output}" ClusterIssuer 1
            assert_kind_count "${phase} Ingress count" "${output}" Ingress 1
            assert_resource_name_count "${phase} ClusterIssuer" "${output}" selfsigned-cluster-issuer 1
            assert_resource_name_count "${phase} Ingress" "${output}" iskaar-ingress 1
            assert_render_contains "${phase} references TLS Secret iskaar-games-tls" "${output}" "secretName: iskaar-games-tls"
            ;;
    esac
}

test_phase_resource_contract() {
    section "Component Phase Resource Contract"

    check_phase Namespace 1 \
        --set components.database=false \
        --set components.backend=false \
        --set components.frontend=false \
        --set components.tls=false

    check_phase Database 5 \
        --set components.database=true \
        --set components.backend=false \
        --set components.frontend=false \
        --set components.tls=false

    check_phase Backend 7 \
        --set components.database=true \
        --set components.backend=true \
        --set components.frontend=false \
        --set components.tls=false

    check_phase Frontend 9 \
        --set components.database=true \
        --set components.backend=true \
        --set components.frontend=true \
        --set components.tls=false

    check_phase TLS 11 \
        --set components.database=true \
        --set components.backend=true \
        --set components.frontend=true \
        --set components.tls=true
}

main() {
    echo "============================================="
    echo " Iskaar Helm Chart Contract Tests"
    echo "============================================="

    if [[ -z "${HELM_BIN}" ]]; then
        if command -v helm >/dev/null 2>&1; then
            HELM_BIN="helm"
        elif command -v helm.exe >/dev/null 2>&1; then
            HELM_BIN="helm.exe"
        else
            echo -e "${RED}ERROR: helm is not installed or not in PATH${NC}" >&2
            exit 1
        fi
    fi

    if ! command -v "${HELM_BIN}" >/dev/null 2>&1 && [[ ! -x "${HELM_BIN}" ]]; then
        echo -e "${RED}ERROR: configured Helm executable is not available: ${HELM_BIN}${NC}" >&2
        exit 1
    fi

    if [[ ! -d "${CHART_DIR}" ]]; then
        echo -e "${RED}ERROR: Helm chart not found at ${CHART_DIR}${NC}" >&2
        exit 1
    fi

    test_schema_contract
    test_chart_lint
    test_flag_matrix
    test_dev_template_renders
    test_stage_template_renders
    test_prod_template_renders
    test_no_latest_tags
    test_tag_injection
    test_registry_prefix_consistency
    test_secret_references
    test_phase_resource_contract

    echo ""
    echo "============================================="
    echo " Summary: ${TESTS_PASSED}/${TESTS_RUN} tests passed"
    echo "============================================="
    echo " Total:  ${TESTS_RUN}"
    echo -e " Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e " Failed: ${RED}${TESTS_FAILED}${NC}"
    echo "============================================="

    if [[ "${TESTS_FAILED}" -gt 0 ]]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi

    echo -e "${GREEN}All tests passed!${NC}"
}

main "$@"
