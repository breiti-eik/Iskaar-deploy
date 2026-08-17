#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Helm Chart Rendering Tests for Iskaar
# Validates: Requirements 3.3, 3.4, 3.5, 3.6, 3.7
# =============================================================================

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_PATH="helm/iskaar"

# --- Test Counters ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Helper Functions ---
pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
    if [ -n "${2:-}" ]; then
        echo -e "        ${YELLOW}Detail: $2${NC}"
    fi
}

section() {
    echo ""
    echo "--- $1 ---"
}

# --- Test Functions ---

test_chart_lint() {
    section "Chart Lint"
    if helm lint "${PROJECT_DIR}/${CHART_PATH}" > /dev/null 2>&1; then
        pass "Chart lint passes"
    else
        fail "Chart lint passes" "helm lint reported errors"
    fi
}

test_dev_template_renders() {
    section "Dev Template Rendering"
    local output
    if output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" -f "${PROJECT_DIR}/${CHART_PATH}/values-dev.yaml" 2>&1); then
        pass "Dev template renders successfully"
    else
        fail "Dev template renders successfully" "${output}"
        return
    fi

    # Dev uses registry prefix (Requirement 3.3)
    if echo "${output}" | grep -q "localhost:5000/iskaar-backend"; then
        pass "Dev uses registry prefix (localhost:5000/iskaar-backend)"
    else
        fail "Dev uses registry prefix (localhost:5000/iskaar-backend)" "localhost:5000/iskaar-backend not found in output"
    fi

    if echo "${output}" | grep -q "localhost:5000/iskaar-frontend"; then
        pass "Dev uses registry prefix (localhost:5000/iskaar-frontend)"
    else
        fail "Dev uses registry prefix (localhost:5000/iskaar-frontend)" "localhost:5000/iskaar-frontend not found in output"
    fi
}

test_stage_template_renders() {
    section "Stage Template Rendering"
    local output
    if output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" -f "${PROJECT_DIR}/${CHART_PATH}/values-stage.yaml" 2>&1); then
        pass "Stage template renders successfully"
    else
        fail "Stage template renders successfully" "${output}"
        return
    fi

    # Stage has resource limits (Requirement 3.4)
    if echo "${output}" | grep -q "cpu:" && echo "${output}" | grep -q "memory:"; then
        pass "Stage has resource limits (cpu and memory present)"
    else
        fail "Stage has resource limits (cpu and memory present)" "cpu: or memory: not found in rendered output"
    fi

    # Verify both requests and limits are present
    if echo "${output}" | grep -q "requests:" && echo "${output}" | grep -q "limits:"; then
        pass "Stage has both requests and limits sections"
    else
        fail "Stage has both requests and limits sections" "requests: or limits: not found in rendered output"
    fi
}

test_prod_template_renders() {
    section "Prod Template Rendering"
    local output
    if output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" -f "${PROJECT_DIR}/${CHART_PATH}/values-prod.yaml" 2>&1); then
        pass "Prod template renders successfully"
    else
        fail "Prod template renders successfully" "${output}"
        return
    fi

    # Prod has >= 2 replicas for backend and frontend deployments (Requirement 3.5)
    # Use awk to extract replicas from Deployment resources only (kind: Deployment + name match)
    local backend_replicas
    backend_replicas=$(echo "${output}" | awk '
        /^---$/ { in_doc=1; is_deployment=0; is_target=0; next }
        /kind: Deployment/ { is_deployment=1 }
        /name: iskaar-backend/ { is_target=1 }
        is_deployment && is_target && /replicas:/ { print $2; exit }
    ')
    local frontend_replicas
    frontend_replicas=$(echo "${output}" | awk '
        /^---$/ { in_doc=1; is_deployment=0; is_target=0; next }
        /kind: Deployment/ { is_deployment=1 }
        /name: iskaar-frontend/ { is_target=1 }
        is_deployment && is_target && /replicas:/ { print $2; exit }
    ')

    local all_ok=true
    if [ -z "${backend_replicas}" ] || [ "${backend_replicas}" -lt 2 ] 2>/dev/null; then
        all_ok=false
    fi
    if [ -z "${frontend_replicas}" ] || [ "${frontend_replicas}" -lt 2 ] 2>/dev/null; then
        all_ok=false
    fi

    if [ "${all_ok}" = true ]; then
        pass "Prod has >= 2 replicas for backend and frontend (backend=${backend_replicas}, frontend=${frontend_replicas})"
    else
        fail "Prod has >= 2 replicas for backend and frontend" "backend=${backend_replicas:-not found}, frontend=${frontend_replicas:-not found}"
    fi
}

test_no_latest_tags() {
    section "No :latest Tags (with explicit --set)"
    local output
    output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" \
        -f "${PROJECT_DIR}/${CHART_PATH}/values-dev.yaml" \
        --set image.backend.tag=v1.0.0 \
        --set image.frontend.tag=v1.0.0 2>&1)

    if echo "${output}" | grep -q ":latest"; then
        fail "No :latest tags when explicit tag is set" "Found ':latest' in rendered output"
    else
        pass "No :latest tags when explicit tag is set"
    fi
}

test_tag_injection() {
    section "Tag Injection"
    local output
    output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" \
        -f "${PROJECT_DIR}/${CHART_PATH}/values-dev.yaml" \
        --set image.backend.tag=v1.0.0 \
        --set image.frontend.tag=v1.0.0 2>&1)

    # Backend tag injection (Requirement 3.7)
    if echo "${output}" | grep -q "localhost:5000/iskaar-backend:v1.0.0"; then
        pass "Tag injection works for backend (localhost:5000/iskaar-backend:v1.0.0)"
    else
        fail "Tag injection works for backend (localhost:5000/iskaar-backend:v1.0.0)" "Expected image reference not found in output"
    fi

    # Frontend tag injection
    if echo "${output}" | grep -q "localhost:5000/iskaar-frontend:v1.0.0"; then
        pass "Tag injection works for frontend (localhost:5000/iskaar-frontend:v1.0.0)"
    else
        fail "Tag injection works for frontend (localhost:5000/iskaar-frontend:v1.0.0)" "Expected image reference not found in output"
    fi
}

test_registry_prefix_consistency() {
    section "Registry Prefix Consistency"

    # Dev environment - all images should use localhost:5000
    local dev_output
    dev_output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" -f "${PROJECT_DIR}/${CHART_PATH}/values-dev.yaml" 2>&1)

    local dev_images
    dev_images=$(echo "${dev_output}" | grep "image:" | grep -v "busybox" | grep -v "postgres:")

    if echo "${dev_images}" | grep -v "localhost:5000/" | grep -q "image:"; then
        fail "Dev registry prefix consistency" "Found images not using localhost:5000/ prefix"
    else
        pass "Dev registry prefix consistency (all app images use localhost:5000/)"
    fi

    # Stage environment - all images should use localhost:5000
    local stage_output
    stage_output=$(helm template iskaar "${PROJECT_DIR}/${CHART_PATH}" -f "${PROJECT_DIR}/${CHART_PATH}/values-stage.yaml" 2>&1)

    local stage_images
    stage_images=$(echo "${stage_output}" | grep "image:" | grep -v "busybox" | grep -v "postgres:")

    if echo "${stage_images}" | grep -v "localhost:5000/" | grep -q "image:"; then
        fail "Stage registry prefix consistency" "Found images not using localhost:5000/ prefix"
    else
        pass "Stage registry prefix consistency (all app images use localhost:5000/)"
    fi
}

# --- Main ---
main() {
    echo "============================================="
    echo " Iskaar Helm Chart Rendering Tests"
    echo "============================================="

    # Verify helm is available
    if ! command -v helm &> /dev/null; then
        echo -e "${RED}ERROR: helm is not installed or not in PATH${NC}"
        exit 1
    fi

    test_chart_lint
    test_dev_template_renders
    test_stage_template_renders
    test_prod_template_renders
    test_no_latest_tags
    test_tag_injection
    test_registry_prefix_consistency

    # --- Summary ---
    echo ""
    echo "============================================="
    echo " Summary: ${TESTS_PASSED}/${TESTS_RUN} tests passed"
    echo "============================================="
    echo -e " Total:  ${TESTS_RUN}"
    echo -e " Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e " Failed: ${RED}${TESTS_FAILED}${NC}"
    echo "============================================="

    if [ "${TESTS_FAILED}" -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
