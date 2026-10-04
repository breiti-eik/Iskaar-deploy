#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Minikube setup helper contract tests
#
# The tests execute scripts/minikube-setup.sh with an isolated command path.
# The fake minikube, kubectl, curl, and helm commands only record arguments and
# return deterministic scenario-specific results. No cluster or network is
# contacted by this test.
#
# Validates: Requirements 4.3, 4.7, 5.1, 5.2, 5.3, 5.4, 5.6, 5.7
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SETUP_SCRIPT="${SCRIPT_DIR}/minikube-setup.sh"
ORIGINAL_PATH="${PATH}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iskaar-minikube-setup-test.XXXXXX")"
MOCK_BIN="${TEST_ROOT}/bin"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CASE_NAME=""
CASE_DIR=""
CASE_STATUS=0

mkdir -p "${MOCK_BIN}"

cleanup_test_root() {
    rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test_root EXIT

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  PASS: %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$1"
    if [[ -n "${2:-}" ]]; then
        printf '        Reason: %s\n' "$2"
    fi
}

write_mock_commands() {
    cat > "${MOCK_BIN}/minikube" <<'MOCK_MINIKUBE'
#!/usr/bin/env bash
set -u

log_call() {
    local command_name="$1"
    shift
    {
        printf '%s' "$command_name"
        local argument
        for argument in "$@"; do
            printf '|%s' "$argument"
        done
        printf '\n'
    } >> "${MOCK_LOG_FILE:?}"
}

state_dir="${MOCK_STATE_DIR:?}"
scenario="${MOCK_SCENARIO:-success}"
log_call minikube "$@"

case "${1:-}" in
    status)
        if [[ ("$scenario" == "stopped-profile" || "$scenario" == "start-timeout") && ! -f "${state_dir}/started" ]]; then
            printf 'Stopped\n'
        else
            printf 'Running\n'
        fi
        ;;
    profile)
        printf '| Name | Status |\n| minikube | Running |\n'
        ;;
    ip)
        printf '%s\n' "${MOCK_MINIKUBE_IP:-192.168.49.2}"
        ;;
    start)
        if [[ "$scenario" == "start-timeout" ]]; then
            # Stop the mock itself so minikube-setup.sh must enforce its wall
            # clock timeout and terminate this child process.
            kill -STOP "$$"
        fi
        : > "${state_dir}/started"
        ;;
    addons)
        case "${2:-}" in
            list)
                if [[ "$scenario" == "disabled-ingress" && ! -f "${state_dir}/ingress-enabled" ]]; then
                    printf '| ingress | ingress | disabled |\n'
                else
                    printf '| ingress | ingress | enabled |\n'
                fi
                ;;
            enable)
                if [[ "${3:-}" == "ingress" ]]; then
                    : > "${state_dir}/ingress-enabled"
                fi
                ;;
        esac
        ;;
    tunnel)
        # Keep the tunnel process alive while the fake curl rejects its
        # endpoints. This models an unusable tunnel without creating a zombie
        # process that would fool the helper's kill -0 check.
        trap 'exit 0' TERM INT
        while :; do
            sleep 1
        done
        ;;
esac
MOCK_MINIKUBE

    cat > "${MOCK_BIN}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -u

log_call() {
    local command_name="$1"
    shift
    {
        printf '%s' "$command_name"
        local argument
        for argument in "$@"; do
            printf '|%s' "$argument"
        done
        printf '\n'
    } >> "${MOCK_LOG_FILE:?}"
}

scenario="${MOCK_SCENARIO:-success}"
log_call kubectl "$@"
joined="$*"

if [[ " $joined " == *" config current-context"* ]]; then
    if [[ "$scenario" == "wrong-context" ]]; then
        printf 'remote-context\n'
    else
        printf 'minikube\n'
    fi
    exit 0
fi

if [[ " $joined " == *" config view"* ]]; then
    printf '%s\n' "${MOCK_API_SERVER:-https://192.168.49.2:8443}"
    exit 0
fi

if [[ " $joined " == *" get --raw=/readyz"* || " $joined " == *" cluster-info"* ]]; then
    exit 0
fi

if [[ " $joined " == *" get crd "* ]]; then
    if [[ "$scenario" == "cert-manager-timeout" ]]; then
        exit 1
    fi
    printf 'crd-ready\n'
    exit 0
fi

if [[ " $joined " == *" get deployment "* ]]; then
    printf 'quay.io/jetstack/cert-manager:%s\n' "${MOCK_CERT_MANAGER_VERSION:-v1.17.2}"
    exit 0
fi

if [[ " $joined " == *" get service "* ]]; then
    # An empty load-balancer address makes the helper use its local fallback.
    exit 0
fi

if [[ " $joined " == *" port-forward "* ]]; then
    trap 'exit 0' TERM INT
    while :; do
        sleep 1
    done
fi

if [[ " $joined " == *" wait "* || " $joined " == *" apply "* ]]; then
    exit 0
fi

exit 0
MOCK_KUBECTL

    cat > "${MOCK_BIN}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -u

log_call() {
    local command_name="$1"
    shift
    {
        printf '%s' "$command_name"
        local argument
        for argument in "$@"; do
            printf '|%s' "$argument"
        done
        printf '\n'
    } >> "${MOCK_LOG_FILE:?}"
}

log_call curl "$@"
if [[ "${MOCK_SCENARIO:-}" == "tunnel-port-forward-fallback" && ( "$*" == *":80:"* || "$*" == *":443:"* ) ]]; then
    exit 1
fi
exit 0
MOCK_CURL

    cat > "${MOCK_BIN}/helm" <<'MOCK_HELM'
#!/usr/bin/env bash
set -u

log_call() {
    local command_name="$1"
    shift
    {
        printf '%s' "$command_name"
        local argument
        for argument in "$@"; do
            printf '|%s' "$argument"
        done
        printf '\n'
    } >> "${MOCK_LOG_FILE:?}"
}

log_call helm "$@"
exit 0
MOCK_HELM

    chmod +x "${MOCK_BIN}/minikube" "${MOCK_BIN}/kubectl" "${MOCK_BIN}/curl" "${MOCK_BIN}/helm"
}

run_case() {
    CASE_NAME="$1"
    shift
    CASE_DIR="${TEST_ROOT}/${CASE_NAME}"
    mkdir -p "${CASE_DIR}/tmp" "${CASE_DIR}/state"
    : > "${CASE_DIR}/commands.log"

    local cert_manager_manifest="https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml"
    local -a common_args=(
        --profile minikube
        --driver docker
        --context minikube
        --registry localhost:5000
        --start-timeout 1
        --ingress-timeout 1
        --certificate-timeout 1
        --issuer-timeout 1
        --access-timeout 1
        --cert-manager-version v1.17.2
        --cert-manager-manifest "${cert_manager_manifest}"
        --cluster-issuer-manifest "${DEPLOY_DIR}/k8s/cluster-issuer.yaml"
        --pid-file "${CASE_DIR}/access.pid"
    )

    if (
        cd "${DEPLOY_DIR}" || exit 1
        export PATH="${MOCK_BIN}:${ORIGINAL_PATH}"
        export MOCK_SCENARIO="${CASE_NAME}"
        export MOCK_STATE_DIR="${CASE_DIR}/state"
        export MOCK_LOG_FILE="${CASE_DIR}/commands.log"
        export MOCK_CERT_MANAGER_VERSION=v1.17.2
        export MOCK_API_SERVER=https://192.168.49.2:8443
        export TMPDIR="${CASE_DIR}/tmp"
        export REGISTRY=localhost:5000
        unset KUBECONFIG
        bash "${SETUP_SCRIPT}" "${common_args[@]}" "$@"
    ) > "${CASE_DIR}/output.log" 2>&1; then
        CASE_STATUS=0
    else
        CASE_STATUS=$?
    fi
}

assert_status() {
    local expected="$1"
    local description="$2"
    if [[ "${CASE_STATUS}" == "${expected}" ]]; then
        pass "${CASE_NAME}: ${description} (exit ${CASE_STATUS})"
    else
        fail "${CASE_NAME}: ${description}" "expected exit ${expected}, got ${CASE_STATUS}; output: $(tr '\n' ' ' < "${CASE_DIR}/output.log")"
    fi
}

assert_nonzero_status() {
    local description="$1"
    if (( CASE_STATUS != 0 )); then
        pass "${CASE_NAME}: ${description} (exit ${CASE_STATUS})"
    else
        fail "${CASE_NAME}: ${description}" "expected a non-zero exit code"
    fi
}

assert_output_contains() {
    local expected="$1"
    local description="$2"
    if grep -Fq -- "${expected}" "${CASE_DIR}/output.log"; then
        pass "${CASE_NAME}: ${description}"
    else
        fail "${CASE_NAME}: ${description}" "missing '${expected}'; output: $(tr '\n' ' ' < "${CASE_DIR}/output.log")"
    fi
}

assert_trace_contains() {
    local expected="$1"
    local description="$2"
    if grep -Fq -- "${expected}" "${CASE_DIR}/commands.log"; then
        pass "${CASE_NAME}: ${description}"
    else
        fail "${CASE_NAME}: ${description}" "missing '${expected}'; trace: $(tr '\n' ' ' < "${CASE_DIR}/commands.log")"
    fi
}

assert_trace_order() {
    local first="$1"
    local second="$2"
    local description="$3"
    local first_line second_line
    first_line="$(grep -n -F -- "${first}" "${CASE_DIR}/commands.log" | head -n 1 | cut -d: -f1)"
    second_line="$(grep -n -F -- "${second}" "${CASE_DIR}/commands.log" | head -n 1 | cut -d: -f1)"
    if [[ -n "${first_line}" && -n "${second_line}" && ${first_line} -lt ${second_line} ]]; then
        pass "${CASE_NAME}: ${description}"
    else
        fail "${CASE_NAME}: ${description}" "trace order was '${first_line}' then '${second_line}'"
    fi
}

assert_no_helm_mutation() {
    local description="$1"
    if grep -Eq '^helm\|.*\|(upgrade|install|rollback)(\||$)' "${CASE_DIR}/commands.log"; then
        fail "${CASE_NAME}: ${description}" "Helm mutation found in command trace"
    else
        pass "${CASE_NAME}: ${description}"
    fi
}

assert_no_namespace_or_secret_mutation() {
    local description="$1"
    if grep -Eiq '^kubectl\|.*\|(apply|create|patch|delete)\|.*(namespace|secret)' "${CASE_DIR}/commands.log"; then
        fail "${CASE_NAME}: ${description}" "Namespace/Secret mutation found in command trace"
    else
        pass "${CASE_NAME}: ${description}"
    fi
}

assert_trace_has_no_secret_value() {
    local description="$1"
    if grep -Eqi 'POSTGRES_(DB|USER|PASSWORD)|secret-value|supersecret' "${CASE_DIR}/commands.log"; then
        fail "${CASE_NAME}: ${description}" "Potential credential value found in command trace"
    else
        pass "${CASE_NAME}: ${description}"
    fi
}

# A stopped profile must be started with the configured local driver and then
# continue through the read-only target checks and setup phases.
test_stopped_profile() {
    echo "[Case] stopped profile is started with the configured driver"
    run_case stopped-profile --access-mode port-forward
    assert_status 0 "stopped profile setup succeeds"
    assert_output_contains "Profile is stopped" "stopped profile is reported"
    assert_output_contains "Minikube setup complete" "setup reaches completion"
    assert_trace_contains "minikube|start|--profile|minikube|--driver|docker" "profile starts with the configured driver"
    assert_trace_contains "kubectl|--context|minikube|-n|ingress-nginx|port-forward|service/ingress-nginx-controller" "port-forward is started"
    assert_no_helm_mutation "no Helm release mutation is performed by the setup helper"
    assert_no_namespace_or_secret_mutation "no namespace or Secret mutation is performed by the setup helper"
    assert_trace_has_no_secret_value "command trace contains no credential values"
}

# A blocked start must be terminated by the helper's configured timeout.
test_start_timeout() {
    echo "[Case] Minikube start timeout"
    run_case start-timeout --access-mode port-forward
    assert_nonzero_status "start timeout fails the setup"
    assert_output_contains "did not start within" "start timeout is diagnosed"
    assert_trace_contains "minikube|start|--profile|minikube|--driver|docker" "the stopped profile start is attempted"
    assert_no_helm_mutation "start failure occurs before Helm release mutation"
    assert_no_namespace_or_secret_mutation "start failure occurs before namespace or Secret mutation"
}

# A context mismatch must be rejected before any start, addon, or application
# resource operation can occur.
test_wrong_context() {
    echo "[Case] wrong Kubernetes context"
    run_case wrong-context --access-mode port-forward
    assert_nonzero_status "wrong context fails the target guard"
    assert_output_contains "does not match the configured local Minikube target" "context mismatch is diagnosed"
    assert_trace_contains "kubectl|config|current-context" "current context is checked"
    if grep -Fq -- "minikube|start" "${CASE_DIR}/commands.log"; then
        fail "${CASE_NAME}: wrong context does not start Minikube" "start command found in trace"
    else
        pass "${CASE_NAME}: wrong context does not start Minikube"
    fi
    assert_no_helm_mutation "wrong context is rejected before Helm release mutation"
    assert_no_namespace_or_secret_mutation "wrong context is rejected before namespace or Secret mutation"
}

# A disabled ingress addon must be activated idempotently before the controller
# readiness gate is evaluated.
test_disabled_ingress() {
    echo "[Case] disabled ingress addon"
    run_case disabled-ingress --access-mode port-forward
    assert_status 0 "disabled ingress addon setup succeeds"
    assert_output_contains "Enabling Minikube ingress addon" "disabled addon is detected"
    assert_output_contains "nginx ingress controller is ready" "ingress controller readiness is confirmed"
    assert_trace_contains "minikube|addons|enable|ingress|--profile|minikube" "disabled ingress addon is enabled"
    assert_no_helm_mutation "ingress setup performs no Helm release mutation"
    assert_no_namespace_or_secret_mutation "ingress setup performs no namespace or Secret mutation"
}

# Missing cert-manager CRDs must time out after the pinned installation attempt
# and before application namespace/Secret or Helm-release mutation.
test_cert_manager_timeout() {
    echo "[Case] cert-manager readiness timeout"
    run_case cert-manager-timeout --access-mode port-forward
    assert_nonzero_status "cert-manager timeout fails the setup"
    assert_output_contains "cert-manager CRDs were not ready within" "cert-manager timeout is diagnosed"
    assert_trace_contains "kubectl|--context|minikube|apply|-f|https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml" "pinned cert-manager setup is attempted"
    assert_no_helm_mutation "cert-manager timeout occurs before Helm release mutation"
    assert_no_namespace_or_secret_mutation "cert-manager timeout occurs before namespace or Secret mutation"
}

# In auto mode a failed tunnel must be followed by a working local
# port-forward, with the effective access mode and URLs reported by the helper.
test_tunnel_port_forward_fallback() {
    echo "[Case] tunnel to port-forward fallback"
    run_case tunnel-port-forward-fallback --access-mode auto
    assert_status 0 "access fallback setup succeeds"
    assert_output_contains "minikube tunnel was not usable; falling back to port-forward" "tunnel failure is reported"
    assert_output_contains "Access mode selected: port-forward" "selected access mode is reported"
    assert_output_contains "Effective HTTP URL: http://iskaar.games:8080" "effective HTTP URL is reported"
    assert_output_contains "Effective HTTPS URL: https://iskaar.games:8443" "effective HTTPS URL is reported"
    assert_trace_contains "minikube|tunnel|--profile|minikube" "tunnel is attempted first"
    assert_trace_contains "kubectl|--context|minikube|-n|ingress-nginx|port-forward|service/ingress-nginx-controller" "port-forward fallback is started"
    assert_trace_order "minikube|tunnel|--profile|minikube" "kubectl|--context|minikube|-n|ingress-nginx|port-forward|service/ingress-nginx-controller" "tunnel precedes port-forward fallback"
    if [[ -e "${CASE_DIR}/access.pid" ]]; then
        fail "${CASE_NAME}: access process artifacts are cleaned up" "PID file remains after successful setup"
    else
        pass "${CASE_NAME}: access process artifacts are cleaned up"
    fi
    assert_no_helm_mutation "access setup performs no Helm release mutation"
    assert_no_namespace_or_secret_mutation "access setup performs no namespace or Secret mutation"
}

if [[ ! -f "${SETUP_SCRIPT}" ]]; then
    printf 'ERROR: Minikube setup helper not found at %s\n' "${SETUP_SCRIPT}" >&2
    exit 1
fi

write_mock_commands

echo "=== Minikube Setup Helper — Mock Contract Tests ==="
echo "Target script: ${SETUP_SCRIPT}"
echo "Mock PATH: ${MOCK_BIN}"
echo ""

test_stopped_profile
test_start_timeout
test_wrong_context
test_disabled_ingress
test_cert_manager_timeout
test_tunnel_port_forward_fallback

echo ""
printf '=== Results: %s passed, %s failed ===\n' "${TESTS_PASSED}" "${TESTS_FAILED}"

if (( TESTS_FAILED > 0 )); then
    exit 1
fi
exit 0
