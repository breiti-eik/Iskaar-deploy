#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Iskaar local Minikube setup helper
#
# This script is intentionally limited to a local Minikube target. It verifies
# the target before the first mutating operation, prepares ingress and
# cert-manager, and manages a temporary tunnel or port-forward for smoke tests.
# No credential value is accepted by this script or written to its output.
#
# Usage:
#   ./minikube-setup.sh [options]
#
# The successful standalone invocation cleans up its access process before
# exiting. Use --keep-access when a caller needs to keep the process alive for
# a subsequent smoke test; the returned PID file then belongs to that caller.
# =============================================================================

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

readonly EXIT_USAGE=2
readonly EXIT_DEPENDENCY=3
readonly EXIT_TARGET=4
readonly EXIT_TIMEOUT=5
readonly EXIT_SETUP=6
readonly EXIT_ACCESS=7

# --- Configuration -----------------------------------------------------------

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CONTEXT="${MINIKUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-iskaar}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_SERVICE="${INGRESS_SERVICE:-ingress-nginx-controller}"
ACCESS_MODE="${ACCESS_MODE:-auto}"
ACCESS_HOST="${ACCESS_HOST:-iskaar.games}"
ACCESS_HTTP_PORT="${ACCESS_HTTP_PORT:-8080}"
ACCESS_HTTPS_PORT="${ACCESS_HTTPS_PORT:-8443}"
TUNNEL_HTTP_PORT="${TUNNEL_HTTP_PORT:-80}"
TUNNEL_HTTPS_PORT="${TUNNEL_HTTPS_PORT:-443}"
ACCESS_TIMEOUT="${ACCESS_TIMEOUT:-60}"
MINIKUBE_START_TIMEOUT="${MINIKUBE_START_TIMEOUT:-180}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-120}"
CERTIFICATE_TIMEOUT="${CERTIFICATE_TIMEOUT:-120}"
CLUSTER_ISSUER_TIMEOUT="${CLUSTER_ISSUER_TIMEOUT:-60}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"

# A blank registry explicitly selects the Minikube Docker daemon. If REGISTRY
# is not set at all, retain the deployment contract's local registry default.
if [[ "${REGISTRY+x}" == x ]]; then
    REGISTRY_VALUE="$REGISTRY"
else
    REGISTRY_VALUE="localhost:5000"
fi

CLUSTER_ISSUER_MANIFEST="${CLUSTER_ISSUER_MANIFEST:-${REPOSITORY_ROOT}/k8s/cluster-issuer.yaml}"
CERT_MANAGER_MANIFEST_EXPLICIT=false
if [[ "${CERT_MANAGER_MANIFEST+x}" == x ]]; then
    CERT_MANAGER_MANIFEST="$CERT_MANAGER_MANIFEST"
    CERT_MANAGER_MANIFEST_EXPLICIT=true
else
    CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
fi
ACCESS_PID_FILE="${ACCESS_PID_FILE:-}"
ACCESS_OUTPUT_FILE="${ACCESS_OUTPUT_FILE:-}"
KEEP_ACCESS=false

# --- Runtime state -----------------------------------------------------------

MINIKUBE=""
KUBECTL=""
CURL=""
PROFILE_STATE=""
CURRENT_CONTEXT=""
KUBE_CONTEXT=""
MINIKUBE_IP=""
ACCESS_MODE_SELECTED=""
ACCESS_ADDRESS=""
ACCESS_HTTP_URL=""
ACCESS_HTTPS_URL=""
ACCESS_PID=""
ACCESS_LOG_FILE=""
ACCESS_ACTIVE=false
CURRENT_PHASE="startup"

# cert-manager CRDs required by the pinned release and by the ClusterIssuer.
readonly CERT_MANAGER_CRDS=(
    "certificates.cert-manager.io"
    "certificaterequests.cert-manager.io"
    "issuers.cert-manager.io"
    "clusterissuers.cert-manager.io"
    "challenges.acme.cert-manager.io"
    "orders.acme.cert-manager.io"
)
readonly CERT_MANAGER_DEPLOYMENTS=(
    "cert-manager"
    "cert-manager-cainjector"
    "cert-manager-webhook"
)

# --- Diagnostics and argument helpers ---------------------------------------

usage() {
    cat <<EOF
Usage: minikube-setup.sh [options]

Prepare and verify a local Minikube target, ingress, cert-manager and local
HTTP/HTTPS access. The script never selects a remote Kubernetes target.

Options:
  --profile <name>                 Minikube profile (default: $MINIKUBE_PROFILE)
  --driver <name>                  Local Minikube driver (default: $MINIKUBE_DRIVER)
  --context <name>                 Expected Kubernetes context (default: profile)
  --kubeconfig <path>              Kubeconfig used for the target
  --registry <host[:port][/path]>  Local registry; blank uses Minikube Docker
  --access-mode <auto|tunnel|port-forward>
                                    Access strategy (default: $ACCESS_MODE)
  --host <hostname>                Ingress hostname (default: $ACCESS_HOST)
  --http-port <port>               Port-forward host port for HTTP (default: $ACCESS_HTTP_PORT)
  --https-port <port>              Port-forward host port for HTTPS (default: $ACCESS_HTTPS_PORT)
  --tunnel-http-port <port>        Minikube tunnel HTTP port (default: $TUNNEL_HTTP_PORT)
  --tunnel-https-port <port>       Minikube tunnel HTTPS port (default: $TUNNEL_HTTPS_PORT)
  --access-timeout <seconds>       Access readiness timeout (default: $ACCESS_TIMEOUT)
  --start-timeout <seconds>        Minikube start/API timeout (default: $MINIKUBE_START_TIMEOUT)
  --ingress-timeout <seconds>      Ingress controller timeout (default: $INGRESS_TIMEOUT)
  --certificate-timeout <seconds>  cert-manager timeout (default: $CERTIFICATE_TIMEOUT)
  --issuer-timeout <seconds>      ClusterIssuer timeout (default: $CLUSTER_ISSUER_TIMEOUT)
  --cert-manager-version <version> Pinned release, e.g. v1.17.2
  --cluster-issuer-manifest <path> ClusterIssuer manifest (default: k8s/cluster-issuer.yaml)
  --cert-manager-manifest <path|url>
                                    Pinned cert-manager manifest source
  --pid-file <path>                Access process PID file
  --output-file <path>             Write non-sensitive access variables to a file
  --keep-access                    Keep tunnel/port-forward after success
  -h, --help                       Show this help

Environment variables use the same names as the corresponding options. The
registry is restricted to localhost/loopback, host.docker.internal, or a
Minikube registry service. No registry credentials are accepted.
EOF
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

fail() {
    local code="$1"
    shift
    printf 'ERROR[%s]: %s\n' "$CURRENT_PHASE" "$*" >&2
    exit "$code"
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        fail "$EXIT_USAGE" "${option} requires a value."
    fi
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        fail "$EXIT_USAGE" "${name} must be a positive integer (received '${value}')."
    fi
}

validate_port() {
    local name="$1"
    local value="$2"
    validate_positive_integer "$name" "$value"
    if (( value > 65535 )); then
        fail "$EXIT_USAGE" "${name} must be between 1 and 65535 (received '${value}')."
    fi
}

validate_safe_name() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        fail "$EXIT_USAGE" "${name} contains unsupported characters."
    fi
}

format_command() {
    local argument
    local formatted=""
    for argument in "$@"; do
        printf -v argument '%q' "$argument"
        if [[ -z "$formatted" ]]; then
            formatted="$argument"
        else
            formatted+=" ${argument}"
        fi
    done
    printf '%s' "$formatted"
}

resolve_command() {
    local name="$1"
    local resolved
    if resolved="$(command -v "$name" 2>/dev/null)"; then
        printf '%s' "$resolved"
        return 0
    fi
    if resolved="$(command -v "${name}.exe" 2>/dev/null)"; then
        printf '%s' "$resolved"
        return 0
    fi
    return 1
}

# --- Portable command execution ---------------------------------------------

# Run a command in the background and enforce a wall-clock timeout without
# relying on GNU timeout, which is not consistently available on Windows/WSL.
run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local child_pid
    local started_at
    local now

    "$@" &
    child_pid=$!
    started_at="$(date +%s)"

    while kill -0 "$child_pid" 2>/dev/null; do
        now="$(date +%s)"
        if (( now - started_at >= timeout_seconds )); then
            kill -TERM "$child_pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
    done

    if wait "$child_pid"; then
        return 0
    else
        local exit_code=$?
        return "$exit_code"
    fi
}

execute_timed() {
    local phase="$1"
    local timeout_seconds="$2"
    shift 2
    CURRENT_PHASE="$phase"
    printf '[%s] Running (timeout=%ss): %s\n' "$phase" "$timeout_seconds" "$(format_command "$@")"
    run_with_timeout "$timeout_seconds" "$@"
}

execute_checked() {
    local phase="$1"
    shift
    CURRENT_PHASE="$phase"
    printf '[%s] Running: %s\n' "$phase" "$(format_command "$@")"
    "$@"
}

wait_until() {
    local timeout_seconds="$1"
    local phase="$2"
    local check_function="$3"
    local started_at
    local now

    CURRENT_PHASE="$phase"
    started_at="$(date +%s)"
    while true; do
        if "$check_function"; then
            printf '[%s] Ready.\n' "$phase"
            return 0
        fi
        now="$(date +%s)"
        if (( now - started_at >= timeout_seconds )); then
            printf 'ERROR[%s]: readiness timed out after %ss.\n' "$phase" "$timeout_seconds" >&2
            return 124
        fi
        sleep 1
    done
}

# --- Configuration validation ------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile|--minikube-profile)
                require_value "$1" "${2:-}"
                MINIKUBE_PROFILE="$2"
                shift 2
                ;;
            --driver|--minikube-driver)
                require_value "$1" "${2:-}"
                MINIKUBE_DRIVER="$2"
                shift 2
                ;;
            --context|--minikube-context)
                require_value "$1" "${2:-}"
                MINIKUBE_CONTEXT="$2"
                shift 2
                ;;
            --kubeconfig)
                require_value "$1" "${2:-}"
                export KUBECONFIG="$2"
                shift 2
                ;;
            --registry)
                # An empty registry is meaningful, so only a missing option
                # value is rejected here; callers can pass --registry= for the
                # Minikube Docker daemon when their shell drops empty args.
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    fail "$EXIT_USAGE" "--registry requires a value; use --registry= for the Minikube Docker daemon."
                fi
                REGISTRY_VALUE="$2"
                shift 2
                ;;
            --registry=*)
                REGISTRY_VALUE="${1#--registry=}"
                shift
                ;;
            --access-mode|--mode)
                require_value "$1" "${2:-}"
                ACCESS_MODE="$2"
                shift 2
                ;;
            --host)
                require_value "$1" "${2:-}"
                ACCESS_HOST="$2"
                shift 2
                ;;
            --http-port)
                require_value "$1" "${2:-}"
                ACCESS_HTTP_PORT="$2"
                shift 2
                ;;
            --https-port)
                require_value "$1" "${2:-}"
                ACCESS_HTTPS_PORT="$2"
                shift 2
                ;;
            --tunnel-http-port)
                require_value "$1" "${2:-}"
                TUNNEL_HTTP_PORT="$2"
                shift 2
                ;;
            --tunnel-https-port)
                require_value "$1" "${2:-}"
                TUNNEL_HTTPS_PORT="$2"
                shift 2
                ;;
            --access-timeout)
                require_value "$1" "${2:-}"
                ACCESS_TIMEOUT="$2"
                shift 2
                ;;
            --start-timeout|--minikube-start-timeout)
                require_value "$1" "${2:-}"
                MINIKUBE_START_TIMEOUT="$2"
                shift 2
                ;;
            --ingress-timeout)
                require_value "$1" "${2:-}"
                INGRESS_TIMEOUT="$2"
                shift 2
                ;;
            --certificate-timeout)
                require_value "$1" "${2:-}"
                CERTIFICATE_TIMEOUT="$2"
                shift 2
                ;;
            --issuer-timeout|--cluster-issuer-timeout)
                require_value "$1" "${2:-}"
                CLUSTER_ISSUER_TIMEOUT="$2"
                shift 2
                ;;
            --cert-manager-version)
                require_value "$1" "${2:-}"
                CERT_MANAGER_VERSION="$2"
                if [[ "$CERT_MANAGER_MANIFEST_EXPLICIT" != true ]]; then
                    CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
                fi
                shift 2
                ;;
            --cluster-issuer-manifest)
                require_value "$1" "${2:-}"
                CLUSTER_ISSUER_MANIFEST="$2"
                shift 2
                ;;
            --cert-manager-manifest)
                require_value "$1" "${2:-}"
                CERT_MANAGER_MANIFEST="$2"
                CERT_MANAGER_MANIFEST_EXPLICIT=true
                shift 2
                ;;
            --pid-file)
                require_value "$1" "${2:-}"
                ACCESS_PID_FILE="$2"
                shift 2
                ;;
            --output-file)
                require_value "$1" "${2:-}"
                ACCESS_OUTPUT_FILE="$2"
                shift 2
                ;;
            --keep-access)
                KEEP_ACCESS=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "$EXIT_USAGE" "Unknown option '$1'. Use --help for usage."
                ;;
        esac
    done

    if [[ -z "$MINIKUBE_CONTEXT" ]]; then
        MINIKUBE_CONTEXT="$MINIKUBE_PROFILE"
    fi
}

validate_kubeconfig_paths() {
    local kubeconfig_value="${KUBECONFIG:-}"
    local separator=':'
    local path
    local -a paths=()

    [[ -z "$kubeconfig_value" ]] && return 0

    # KUBECONFIG uses ':' on Unix and ';' on Windows. Do not echo the value;
    # kubeconfig files can contain client credentials.
    if [[ "$kubeconfig_value" == *';'* ]]; then
        separator=';'
    fi
    local old_ifs="$IFS"
    IFS="$separator" read -r -a paths <<< "$kubeconfig_value"
    IFS="$old_ifs"

    for path in "${paths[@]}"; do
        if [[ -z "$path" || ! -f "$path" ]]; then
            fail "$EXIT_TARGET" "KUBECONFIG contains a missing local file; remote or unresolved kubeconfig paths are not accepted."
        fi
    done
}

registry_host() {
    local registry="$REGISTRY_VALUE"
    local authority
    local host

    [[ -z "$registry" ]] && return 0
    if [[ "$registry" == *'://'* || "$registry" == *'@'* || "$registry" == *[[:space:]]* ]]; then
        fail "$EXIT_TARGET" "REGISTRY must be a local host[:port][/path] without a URL scheme or credentials."
    fi

    authority="${registry%%/*}"
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority%%\]*}"
        host="${host#\[}"
    else
        host="${authority%%:*}"
    fi
    printf '%s' "$host"
}

validate_local_registry() {
    local host
    host="$(registry_host)"
    [[ -z "$host" ]] && return 0

    case "$host" in
        localhost|host.docker.internal|127.*|::1)
            return 0
            ;;
        registry|registry.*.svc.cluster.local)
            return 0
            ;;
        *)
            fail "$EXIT_TARGET" "Remote registry '$host' is not allowed; use localhost, a loopback address, host.docker.internal, a Minikube registry service, or an empty registry."
            ;;
    esac
}

validate_configuration() {
    CURRENT_PHASE="configuration"

    validate_safe_name "MINIKUBE_PROFILE" "$MINIKUBE_PROFILE"
    validate_safe_name "MINIKUBE_CONTEXT" "$MINIKUBE_CONTEXT"
    validate_safe_name "NAMESPACE" "$NAMESPACE"
    validate_safe_name "INGRESS_NAMESPACE" "$INGRESS_NAMESPACE"
    validate_safe_name "INGRESS_SERVICE" "$INGRESS_SERVICE"

    case "$MINIKUBE_DRIVER" in
        docker|podman|virtualbox|hyperv|hyperkit|kvm2|qemu2|vfkit|none)
            ;;
        *)
            fail "$EXIT_TARGET" "Minikube driver '$MINIKUBE_DRIVER' is not an accepted local driver."
            ;;
    esac

    case "$ACCESS_MODE" in
        auto|tunnel|port-forward)
            ;;
        *)
            fail "$EXIT_USAGE" "ACCESS_MODE must be exactly auto, tunnel, or port-forward."
            ;;
    esac

    if [[ ! "$ACCESS_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && "$ACCESS_HOST" != "localhost" ]]; then
        fail "$EXIT_USAGE" "ACCESS_HOST must be a hostname without a scheme, path, port, or credentials."
    fi
    if [[ "$ACCESS_HOST" == *..* || "$ACCESS_HOST" == *'/'* || "$ACCESS_HOST" == *':'* ]]; then
        fail "$EXIT_USAGE" "ACCESS_HOST contains an invalid hostname."
    fi

    validate_port "ACCESS_HTTP_PORT" "$ACCESS_HTTP_PORT"
    validate_port "ACCESS_HTTPS_PORT" "$ACCESS_HTTPS_PORT"
    validate_port "TUNNEL_HTTP_PORT" "$TUNNEL_HTTP_PORT"
    validate_port "TUNNEL_HTTPS_PORT" "$TUNNEL_HTTPS_PORT"
    validate_positive_integer "ACCESS_TIMEOUT" "$ACCESS_TIMEOUT"
    validate_positive_integer "MINIKUBE_START_TIMEOUT" "$MINIKUBE_START_TIMEOUT"
    validate_positive_integer "INGRESS_TIMEOUT" "$INGRESS_TIMEOUT"
    validate_positive_integer "CERTIFICATE_TIMEOUT" "$CERTIFICATE_TIMEOUT"
    validate_positive_integer "CLUSTER_ISSUER_TIMEOUT" "$CLUSTER_ISSUER_TIMEOUT"

    if [[ ! "$CERT_MANAGER_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        fail "$EXIT_USAGE" "CERT_MANAGER_VERSION must be a pinned semantic version such as v1.17.2."
    fi

    if [[ ! -f "$CLUSTER_ISSUER_MANIFEST" ]]; then
        fail "$EXIT_SETUP" "ClusterIssuer manifest not found at '$CLUSTER_ISSUER_MANIFEST'."
    fi

    if [[ "$CERT_MANAGER_MANIFEST" == http://* ]]; then
        fail "$EXIT_SETUP" "cert-manager manifest must use HTTPS or a local file; insecure URLs are not accepted."
    fi
    if [[ "$CERT_MANAGER_MANIFEST" != https://* && ! -f "$CERT_MANAGER_MANIFEST" ]]; then
        fail "$EXIT_SETUP" "cert-manager manifest not found at '$CERT_MANAGER_MANIFEST'."
    fi
    if [[ "$CERT_MANAGER_MANIFEST" == https://* && "$CERT_MANAGER_MANIFEST" != *"/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" ]]; then
        fail "$EXIT_SETUP" "cert-manager URL is not pinned to ${CERT_MANAGER_VERSION}."
    fi

    if [[ -n "$ACCESS_PID_FILE" ]]; then
        local pid_parent
        pid_parent="$(dirname -- "$ACCESS_PID_FILE")"
        if [[ ! -d "$pid_parent" ]]; then
            fail "$EXIT_SETUP" "PID file parent directory does not exist: '$pid_parent'."
        fi
    fi
    if [[ -n "$ACCESS_OUTPUT_FILE" ]]; then
        local output_parent
        output_parent="$(dirname -- "$ACCESS_OUTPUT_FILE")"
        if [[ ! -d "$output_parent" ]]; then
            fail "$EXIT_SETUP" "Output file parent directory does not exist: '$output_parent'."
        fi
    fi

    validate_kubeconfig_paths
    validate_local_registry
}

print_configuration() {
    local registry_display="$REGISTRY_VALUE"
    if [[ -z "$registry_display" ]]; then
        registry_display="minikube-docker-daemon"
    fi

    echo "Target: local Minikube"
    echo "Minikube profile: ${MINIKUBE_PROFILE}"
    echo "Minikube driver: ${MINIKUBE_DRIVER}"
    echo "Expected Kubernetes context: ${MINIKUBE_CONTEXT}"
    echo "Registry: ${registry_display}"
    echo "Access mode: ${ACCESS_MODE}"
    echo "Access timeout: ${ACCESS_TIMEOUT}s"
    echo "cert-manager version: ${CERT_MANAGER_VERSION}"
}

# --- Local Minikube target verification -------------------------------------

get_profile_state() {
    local output=""
    local fallback_output=""

    if ! output="$( "$MINIKUBE" status --profile "$MINIKUBE_PROFILE" --format='{{.Host}}' 2>/dev/null)"; then
        :
    fi
    output="$(trim "$output")"

    if [[ -z "$output" ]]; then
        if ! fallback_output="$( "$MINIKUBE" status --profile "$MINIKUBE_PROFILE" 2>/dev/null)"; then
            :
        fi
        output="$(trim "$fallback_output")"
    fi

    local normalized="${output,,}"
    case "$normalized" in
        *nonexistent*|*"not found"*)
            PROFILE_STATE="Nonexistent"
            ;;
        *stopped*)
            PROFILE_STATE="Stopped"
            ;;
        *running*)
            PROFILE_STATE="Running"
            ;;
        *)
            fail "$EXIT_TARGET" "Unable to determine the state of Minikube profile '${MINIKUBE_PROFILE}'. The read-only status check returned no recognized state."
            ;;
    esac
    echo "[target] Minikube profile state: ${PROFILE_STATE}"
}

verify_profile_inventory() {
    local output=""
    local normalized_profile="${MINIKUBE_PROFILE,,}"

    # `profile list` is read-only. Older Minikube versions may not support it;
    # the profile-specific status check remains authoritative in that case.
    if ! output="$( "$MINIKUBE" profile list 2>/dev/null)"; then
        echo "[target] Profile inventory command unavailable; using profile-specific status and context checks."
        return 0
    fi
    if [[ -z "$(trim "$output")" || "$PROFILE_STATE" == "Nonexistent" ]]; then
        return 0
    fi
    if [[ "${output,,}" != *"$normalized_profile"* ]]; then
        fail "$EXIT_TARGET" "Minikube profile '${MINIKUBE_PROFILE}' was not present in the read-only profile inventory."
    fi
}

read_current_context() {
    local output=""
    if ! output="$( "$KUBECTL" config current-context 2>/dev/null)"; then
        fail "$EXIT_TARGET" "Unable to read the current Kubernetes context with kubectl."
    fi
    CURRENT_CONTEXT="$(trim "$output")"
    if [[ -z "$CURRENT_CONTEXT" ]]; then
        fail "$EXIT_TARGET" "kubectl returned an empty Kubernetes context."
    fi
    if [[ "$CURRENT_CONTEXT" != "$MINIKUBE_CONTEXT" && "$CURRENT_CONTEXT" != "$MINIKUBE_PROFILE" ]]; then
        fail "$EXIT_TARGET" "Kubernetes context '${CURRENT_CONTEXT}' does not match the configured local Minikube target '${MINIKUBE_CONTEXT}'."
    fi
    KUBE_CONTEXT="$CURRENT_CONTEXT"
    echo "[target] Kubernetes context verified: ${KUBE_CONTEXT}"
}

query_minikube_ip() {
    local output=""
    if ! output="$( "$MINIKUBE" ip --profile "$MINIKUBE_PROFILE" 2>/dev/null)"; then
        return 1
    fi
    output="$(trim "$output")"
    if [[ "$output" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        MINIKUBE_IP="$output"
        return 0
    fi
    return 1
}

query_api_server() {
    local output=""
    if ! output="$( "$KUBECTL" --context "$KUBE_CONTEXT" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)"; then
        return 1
    fi
    output="$(trim "$output")"
    [[ -n "$output" ]] || return 1
    printf '%s' "$output"
}

extract_server_host() {
    local server_url="$1"
    local authority
    local host

    if [[ "$server_url" != *://* ]]; then
        return 1
    fi
    authority="${server_url#*://}"
    authority="${authority%%/*}"
    if [[ "$authority" == *'@'* || -z "$authority" ]]; then
        return 1
    fi
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority%%\]*}"
        host="${host#\[}"
    else
        host="${authority%%:*}"
    fi
    [[ -n "$host" ]] || return 1
    printf '%s' "$host"
}

is_local_server_host() {
    local host="$1"
    [[ "$host" == "localhost" || "$host" == "::1" || "$host" == "$MINIKUBE_IP" ]] && return 0
    [[ "$host" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    return 1
}

verify_local_server() {
    CURRENT_PHASE="target-server"
    local server_url
    local host

    if ! query_minikube_ip; then
        if [[ "$PROFILE_STATE" == "Stopped" || "$PROFILE_STATE" == "Nonexistent" ]]; then
            fail "$EXIT_TARGET" "Minikube did not provide a local profile IP for '${MINIKUBE_PROFILE}'; refusing to start or use an unverified target."
        fi
        fail "$EXIT_TARGET" "Unable to read the local Minikube IP for '${MINIKUBE_PROFILE}'."
    fi

    if ! server_url="$(query_api_server)"; then
        fail "$EXIT_TARGET" "Unable to inspect the Kubernetes API server for context '${KUBE_CONTEXT}'."
    fi
    if ! host="$(extract_server_host "$server_url")"; then
        fail "$EXIT_TARGET" "The Kubernetes API server address could not be parsed safely."
    fi
    if ! is_local_server_host "$host"; then
        fail "$EXIT_TARGET" "Kubernetes API server host '${host}' is not the local Minikube server '${MINIKUBE_IP}'."
    fi
    echo "[target] Local Kubernetes API server verified: ${host}"
}

api_is_ready() {
    if "$KUBECTL" --context "$KUBE_CONTEXT" get --raw=/readyz --request-timeout=5s >/dev/null 2>&1; then
        return 0
    fi
    "$KUBECTL" --context "$KUBE_CONTEXT" cluster-info --request-timeout=5s >/dev/null 2>&1
}

wait_for_api() {
    if ! wait_until "$MINIKUBE_START_TIMEOUT" "kubernetes-api" api_is_ready; then
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' get --raw=/readyz --request-timeout=5s" >&2
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' cluster-info" >&2
        fail "$EXIT_TIMEOUT" "Kubernetes API was not ready within ${MINIKUBE_START_TIMEOUT}s."
    fi
}

verify_target_before_mutation() {
    CURRENT_PHASE="target-verification"
    get_profile_state
    verify_profile_inventory

    if [[ "$PROFILE_STATE" == "Nonexistent" ]]; then
        # A new profile may not have a kubeconfig context yet. If one exists,
        # it still must not point at a different target.
        local context_output=""
        if context_output="$( "$KUBECTL" config current-context 2>/dev/null)"; then
            context_output="$(trim "$context_output")"
            if [[ -n "$context_output" && "$context_output" != "$MINIKUBE_CONTEXT" && "$context_output" != "$MINIKUBE_PROFILE" ]]; then
                fail "$EXIT_TARGET" "Existing Kubernetes context '${context_output}' is not the requested local Minikube target."
            fi
        fi
        echo "[target] Profile does not exist yet; only the explicit local Minikube start may create it."
        return 0
    fi

    read_current_context
    verify_local_server

    if [[ "$PROFILE_STATE" == "Running" ]]; then
        wait_for_api
    else
        echo "[target] Profile is stopped; API readiness will be checked immediately after the explicit local start."
    fi
}

ensure_profile_running() {
    CURRENT_PHASE="minikube-start"
    if [[ "$PROFILE_STATE" == "Running" ]]; then
        echo "[minikube-start] Profile already running; no start mutation required."
        return 0
    fi

    if execute_timed "minikube-start" "$MINIKUBE_START_TIMEOUT" \
        "$MINIKUBE" start --profile "$MINIKUBE_PROFILE" --driver "$MINIKUBE_DRIVER"; then
        :
    else
        local exit_code=$?
        echo "Diagnostics: minikube status --profile '${MINIKUBE_PROFILE}'" >&2
        fail "$EXIT_TIMEOUT" "Minikube profile '${MINIKUBE_PROFILE}' did not start within ${MINIKUBE_START_TIMEOUT}s (exit ${exit_code})."
    fi

    get_profile_state
    if [[ "$PROFILE_STATE" != "Running" ]]; then
        fail "$EXIT_SETUP" "Minikube start returned successfully but profile '${MINIKUBE_PROFILE}' is not Running."
    fi
    read_current_context
    verify_local_server
    wait_for_api
}

# --- Ingress setup -----------------------------------------------------------

ingress_addon_enabled() {
    local output=""
    local line
    if ! output="$( "$MINIKUBE" addons list --profile "$MINIKUBE_PROFILE" 2>/dev/null)"; then
        return 1
    fi
    while IFS= read -r line; do
        local normalized_line="${line,,}"
        if [[ "$normalized_line" == *ingress* && "$normalized_line" == *enabled* && "$normalized_line" != *disabled* ]]; then
            return 0
        fi
    done <<< "$output"
    return 1
}

wait_for_ingress_controller() {
    if execute_timed "ingress-controller" "$INGRESS_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" -n "$INGRESS_NAMESPACE" wait \
        --for=condition=available "deployment/${INGRESS_SERVICE}" \
        --timeout="${INGRESS_TIMEOUT}s"; then
        return 0
    fi

    # Some Minikube versions expose the controller as a pod without an
    # Available deployment condition. Keep the fallback read-only and scoped.
    echo "[ingress-controller] Deployment condition was not ready; checking controller pods." >&2
    if execute_timed "ingress-controller-pods" "$INGRESS_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" -n "$INGRESS_NAMESPACE" wait \
        --for=condition=ready pod -l app.kubernetes.io/component=controller \
        --timeout="${INGRESS_TIMEOUT}s"; then
        return 0
    fi
    echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n '${INGRESS_NAMESPACE}' get pods -l app.kubernetes.io/component=controller -o wide" >&2
    echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n '${INGRESS_NAMESPACE}' get events --sort-by=.lastTimestamp" >&2
    return 1
}

ensure_ingress() {
    CURRENT_PHASE="ingress-addon"
    if ingress_addon_enabled; then
        echo "[ingress-addon] Minikube ingress addon is already enabled."
    else
        echo "[ingress-addon] Enabling Minikube ingress addon."
        if execute_timed "ingress-addon-enable" "$INGRESS_TIMEOUT" \
            "$MINIKUBE" addons enable ingress --profile "$MINIKUBE_PROFILE"; then
            :
        else
            local exit_code=$?
            echo "Diagnostics: minikube addons list --profile '${MINIKUBE_PROFILE}'" >&2
            fail "$EXIT_SETUP" "The Minikube ingress addon could not be enabled (exit ${exit_code})."
        fi
        if ! ingress_addon_enabled; then
            echo "Diagnostics: minikube addons list --profile '${MINIKUBE_PROFILE}'" >&2
            fail "$EXIT_SETUP" "The ingress addon did not report enabled after activation."
        fi
    fi

    if ! wait_for_ingress_controller; then
        fail "$EXIT_TIMEOUT" "The nginx ingress controller was not ready within ${INGRESS_TIMEOUT}s."
    fi
    echo "[ingress-addon] nginx ingress controller is ready."
}

# --- cert-manager and ClusterIssuer -----------------------------------------

cert_manager_crds_ready() {
    local crd
    local output
    for crd in "${CERT_MANAGER_CRDS[@]}"; do
        if ! output="$( "$KUBECTL" --context "$KUBE_CONTEXT" get crd "$crd" -o name 2>/dev/null)"; then
            return 1
        fi
        [[ -n "$(trim "$output")" ]] || return 1
    done
    return 0
}

cert_manager_version_ready() {
    local deployment
    local image
    for deployment in "${CERT_MANAGER_DEPLOYMENTS[@]}"; do
        if ! image="$( "$KUBECTL" --context "$KUBE_CONTEXT" -n cert-manager get deployment "$deployment" -o 'jsonpath={.spec.template.spec.containers[0].image}' 2>/dev/null)"; then
            return 1
        fi
        image="$(trim "$image")"
        if [[ -z "$image" || "$image" != *":${CERT_MANAGER_VERSION}" && "$image" != *"@${CERT_MANAGER_VERSION}" ]]; then
            return 1
        fi
    done
    return 0
}

cert_manager_is_ready() {
    cert_manager_crds_ready && cert_manager_version_ready
}

apply_cert_manager_manifest() {
    local source="$CERT_MANAGER_MANIFEST"
    if [[ "$source" == https://* ]]; then
        echo "[cert-manager] Applying pinned manifest for ${CERT_MANAGER_VERSION}."
    else
        echo "[cert-manager] Applying local manifest for pinned version ${CERT_MANAGER_VERSION}."
    fi
    execute_timed "cert-manager-install" "$CERTIFICATE_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" apply -f "$source"
}

wait_for_cert_manager_crds() {
    if ! wait_until "$CERTIFICATE_TIMEOUT" "cert-manager-crds" cert_manager_crds_ready; then
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' get crd | grep cert-manager" >&2
        fail "$EXIT_TIMEOUT" "cert-manager CRDs were not ready within ${CERTIFICATE_TIMEOUT}s."
    fi
}

wait_for_cert_manager_workloads() {
    if ! execute_timed "cert-manager-deployments" "$CERTIFICATE_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" -n cert-manager wait \
        --for=condition=available "deployment/${CERT_MANAGER_DEPLOYMENTS[0]}" \
        "deployment/${CERT_MANAGER_DEPLOYMENTS[1]}" "deployment/${CERT_MANAGER_DEPLOYMENTS[2]}" \
        --timeout="${CERTIFICATE_TIMEOUT}s"; then
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n cert-manager get deployments -o wide" >&2
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n cert-manager get pods -o wide" >&2
        fail "$EXIT_TIMEOUT" "cert-manager controller, cainjector, and webhook deployments were not available within ${CERTIFICATE_TIMEOUT}s."
    fi

    if execute_timed "cert-manager-pods" "$CERTIFICATE_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" -n cert-manager wait \
        --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager \
        --timeout="${CERTIFICATE_TIMEOUT}s"; then
        return 0
    fi

    # Label layouts changed between cert-manager releases; verify all pods as
    # a bounded fallback rather than accepting an unverified controller state.
    if ! execute_timed "cert-manager-pods-fallback" "$CERTIFICATE_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" -n cert-manager wait \
        --for=condition=ready pod --all --timeout="${CERTIFICATE_TIMEOUT}s"; then
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n cert-manager get pods -o wide" >&2
        fail "$EXIT_TIMEOUT" "cert-manager pods were not Ready within ${CERTIFICATE_TIMEOUT}s."
    fi
}

ensure_cert_manager() {
    CURRENT_PHASE="cert-manager"
    if cert_manager_is_ready; then
        echo "[cert-manager] Existing cert-manager installation matches pinned version ${CERT_MANAGER_VERSION}."
    else
        echo "[cert-manager] Installation is missing or differs from pinned version; applying ${CERT_MANAGER_VERSION}."
        if apply_cert_manager_manifest; then
            :
        else
            local exit_code=$?
            fail "$EXIT_SETUP" "Pinned cert-manager installation failed (exit ${exit_code})."
        fi
    fi

    wait_for_cert_manager_crds
    wait_for_cert_manager_workloads
    echo "[cert-manager] Controller, cainjector, webhook, and CRDs are ready."
}

ensure_cluster_issuer() {
    CURRENT_PHASE="cluster-issuer"
    if execute_checked "cluster-issuer-apply" \
        "$KUBECTL" --context "$KUBE_CONTEXT" apply -f "$CLUSTER_ISSUER_MANIFEST"; then
        :
    else
        local exit_code=$?
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' get clusterissuer" >&2
        fail "$EXIT_SETUP" "ClusterIssuer manifest application failed (exit ${exit_code})."
    fi

    if ! execute_timed "cluster-issuer-ready" "$CLUSTER_ISSUER_TIMEOUT" \
        "$KUBECTL" --context "$KUBE_CONTEXT" wait \
        --for=condition=Ready "clusterissuer/selfsigned-cluster-issuer" \
        --timeout="${CLUSTER_ISSUER_TIMEOUT}s"; then
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' get clusterissuer selfsigned-cluster-issuer -o wide" >&2
        echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' describe clusterissuer selfsigned-cluster-issuer" >&2
        fail "$EXIT_TIMEOUT" "ClusterIssuer selfsigned-cluster-issuer was not Ready within ${CLUSTER_ISSUER_TIMEOUT}s."
    fi
    echo "[cluster-issuer] selfsigned-cluster-issuer is Ready."
}

# --- Access manager ----------------------------------------------------------

create_access_artifacts() {
    local temporary_root="${TMPDIR:-/tmp}"
    if [[ -z "$ACCESS_PID_FILE" ]]; then
        ACCESS_PID_FILE="${temporary_root}/iskaar-minikube-access-${MINIKUBE_PROFILE}-$$.pid"
    fi
    ACCESS_LOG_FILE="${temporary_root}/iskaar-minikube-access-${MINIKUBE_PROFILE}-$$.log"
    : > "$ACCESS_LOG_FILE"
}

process_is_alive() {
    [[ -n "$ACCESS_PID" ]] && [[ "$ACCESS_PID" =~ ^[0-9]+$ ]] && kill -0 "$ACCESS_PID" 2>/dev/null
}

cleanup_access() {
    if [[ "$ACCESS_ACTIVE" == true && -n "$ACCESS_PID" && "$ACCESS_PID" =~ ^[0-9]+$ ]]; then
        if kill -0 "$ACCESS_PID" 2>/dev/null; then
            kill -TERM "$ACCESS_PID" 2>/dev/null || true
            local deadline=$(( $(date +%s) + 5 ))
            while kill -0 "$ACCESS_PID" 2>/dev/null && (( $(date +%s) < deadline )); do
                sleep 1
            done
            kill -KILL "$ACCESS_PID" 2>/dev/null || true
            wait "$ACCESS_PID" 2>/dev/null || true
        fi
    fi
    ACCESS_ACTIVE=false
    ACCESS_PID=""
    if [[ -n "$ACCESS_PID_FILE" && -f "$ACCESS_PID_FILE" ]]; then
        rm -f -- "$ACCESS_PID_FILE"
    fi
    if [[ -n "$ACCESS_LOG_FILE" && -f "$ACCESS_LOG_FILE" ]]; then
        rm -f -- "$ACCESS_LOG_FILE"
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    if [[ "$ACCESS_ACTIVE" == true && ( "$KEEP_ACCESS" != true || "$exit_code" -ne 0 ) ]]; then
        cleanup_access
    fi
    return "$exit_code"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

start_access_process() {
    create_access_artifacts
    "$@" >"$ACCESS_LOG_FILE" 2>&1 &
    ACCESS_PID=$!
    ACCESS_ACTIVE=true
    printf '%s\n' "$ACCESS_PID" > "$ACCESS_PID_FILE"
    echo "[access] Started process (pid file: ${ACCESS_PID_FILE})."
}

query_load_balancer_address() {
    local address=""
    if ! address="$( "$KUBECTL" --context "$KUBE_CONTEXT" -n "$INGRESS_NAMESPACE" get service "$INGRESS_SERVICE" -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"; then
        :
    fi
    address="$(trim "$address")"
    if [[ -z "$address" ]]; then
        if ! address="$( "$KUBECTL" --context "$KUBE_CONTEXT" -n "$INGRESS_NAMESPACE" get service "$INGRESS_SERVICE" -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"; then
            :
        fi
        address="$(trim "$address")"
    fi
    printf '%s' "$address"
}

is_local_access_address() {
    local address="$1"
    [[ -z "$address" || "$address" == "localhost" || "$address" == "::1" || "$address" == "$MINIKUBE_IP" ]] && return 0
    [[ "$address" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ "$address" == *.local || "$address" == *.svc.cluster.local ]] && return 0
    return 1
}

make_access_urls() {
    if [[ "$ACCESS_MODE_SELECTED" == "tunnel" ]]; then
        if [[ "$TUNNEL_HTTP_PORT" == 80 ]]; then
            ACCESS_HTTP_URL="http://${ACCESS_HOST}"
        else
            ACCESS_HTTP_URL="http://${ACCESS_HOST}:${TUNNEL_HTTP_PORT}"
        fi
        if [[ "$TUNNEL_HTTPS_PORT" == 443 ]]; then
            ACCESS_HTTPS_URL="https://${ACCESS_HOST}"
        else
            ACCESS_HTTPS_URL="https://${ACCESS_HOST}:${TUNNEL_HTTPS_PORT}"
        fi
    else
        ACCESS_HTTP_URL="http://${ACCESS_HOST}:${ACCESS_HTTP_PORT}"
        ACCESS_HTTPS_URL="https://${ACCESS_HOST}:${ACCESS_HTTPS_PORT}"
    fi
}

curl_access_probe() {
    local url="$1"
    local port="$2"
    "$CURL" --silent --show-error --insecure --noproxy '*' \
        --connect-timeout 2 --max-time 5 \
        --resolve "${ACCESS_HOST}:${port}:${ACCESS_ADDRESS}" \
        -o /dev/null "$url" >/dev/null 2>&1
}

access_endpoints_ready() {
    process_is_alive || return 1
    if [[ "$ACCESS_MODE_SELECTED" == "tunnel" && -z "$ACCESS_ADDRESS" ]]; then
        ACCESS_ADDRESS="$(query_load_balancer_address)"
        if [[ -z "$ACCESS_ADDRESS" ]]; then
            ACCESS_ADDRESS="127.0.0.1"
        fi
    fi
    local http_probe_port="$ACCESS_HTTP_PORT"
    local https_probe_port="$ACCESS_HTTPS_PORT"
    if [[ "$ACCESS_MODE_SELECTED" == "tunnel" ]]; then
        http_probe_port="$TUNNEL_HTTP_PORT"
        https_probe_port="$TUNNEL_HTTPS_PORT"
    fi
    curl_access_probe "$ACCESS_HTTP_URL" "$http_probe_port" || return 1
    curl_access_probe "$ACCESS_HTTPS_URL" "$https_probe_port"
}

emit_access_diagnostics() {
    echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n '${INGRESS_NAMESPACE}' get service '${INGRESS_SERVICE}' -o wide" >&2
    echo "Diagnostics: kubectl --context '${KUBE_CONTEXT}' -n '${INGRESS_NAMESPACE}' get pods -o wide" >&2
    echo "Diagnostics: access process log is retained at '${ACCESS_LOG_FILE}' until cleanup." >&2
}

start_tunnel_and_wait() {
    ACCESS_MODE_SELECTED="tunnel"
    ACCESS_ADDRESS="$(query_load_balancer_address)"
    if [[ -n "$ACCESS_ADDRESS" ]] && ! is_local_access_address "$ACCESS_ADDRESS"; then
        echo "[access] Existing LoadBalancer address is not local; refusing tunnel access." >&2
        return 1
    fi
    if [[ -z "$ACCESS_ADDRESS" ]]; then
        ACCESS_ADDRESS="127.0.0.1"
    fi
    make_access_urls
    start_access_process "$MINIKUBE" tunnel --profile "$MINIKUBE_PROFILE"
    if wait_until "$ACCESS_TIMEOUT" "access-tunnel" access_endpoints_ready; then
        echo "[access] minikube tunnel is reachable."
        return 0
    fi
    emit_access_diagnostics
    return 1
}

start_port_forward_and_wait() {
    ACCESS_MODE_SELECTED="port-forward"
    ACCESS_ADDRESS="127.0.0.1"
    make_access_urls
    start_access_process "$KUBECTL" --context "$KUBE_CONTEXT" -n "$INGRESS_NAMESPACE" \
        port-forward "service/${INGRESS_SERVICE}" \
        "${ACCESS_HTTP_PORT}:80" "${ACCESS_HTTPS_PORT}:443" \
        --address 127.0.0.1
    if wait_until "$ACCESS_TIMEOUT" "access-port-forward" access_endpoints_ready; then
        echo "[access] Kubernetes port-forward is reachable."
        return 0
    fi
    emit_access_diagnostics
    return 1
}

setup_access() {
    CURRENT_PHASE="access"
    case "$ACCESS_MODE" in
        tunnel)
            if ! start_tunnel_and_wait; then
                cleanup_access
                fail "$EXIT_ACCESS" "minikube tunnel was not usable within ${ACCESS_TIMEOUT}s."
            fi
            ;;
        port-forward)
            if ! start_port_forward_and_wait; then
                cleanup_access
                fail "$EXIT_ACCESS" "Kubernetes port-forward was not usable within ${ACCESS_TIMEOUT}s."
            fi
            ;;
        auto)
            if start_tunnel_and_wait; then
                :
            else
                echo "[access] minikube tunnel was not usable; falling back to port-forward."
                cleanup_access
                if ! start_port_forward_and_wait; then
                    cleanup_access
                    fail "$EXIT_ACCESS" "Neither minikube tunnel nor Kubernetes port-forward was usable within ${ACCESS_TIMEOUT}s."
                fi
            fi
            ;;
    esac
}

write_access_output() {
    [[ -z "$ACCESS_OUTPUT_FILE" ]] && return 0
    umask 077
    {
        printf 'ACCESS_MODE=%s\n' "$ACCESS_MODE_SELECTED"
        printf 'ACCESS_ADDRESS=%s\n' "$ACCESS_ADDRESS"
        printf 'HTTP_URL=%s\n' "$ACCESS_HTTP_URL"
        printf 'HTTPS_URL=%s\n' "$ACCESS_HTTPS_URL"
        printf 'ACCESS_PID=%s\n' "$ACCESS_PID"
        printf 'ACCESS_PID_FILE=%s\n' "$ACCESS_PID_FILE"
    } > "$ACCESS_OUTPUT_FILE"
}

print_access_summary() {
    echo "Access mode selected: ${ACCESS_MODE_SELECTED}"
    echo "Effective HTTP URL: ${ACCESS_HTTP_URL}"
    echo "Effective HTTPS URL: ${ACCESS_HTTPS_URL}"
    echo "Access address: ${ACCESS_ADDRESS}"
    echo "Access PID file: ${ACCESS_PID_FILE}"
    if [[ "$KEEP_ACCESS" == true ]]; then
        echo "Access process: kept for caller cleanup"
    else
        echo "Access process: cleaned up on successful exit"
    fi
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_configuration

    MINIKUBE="$(resolve_command minikube || true)"
    KUBECTL="$(resolve_command kubectl || true)"
    CURL="$(resolve_command curl || true)"
    local missing_tools=()
    [[ -n "$MINIKUBE" ]] || missing_tools+=(minikube)
    [[ -n "$KUBECTL" ]] || missing_tools+=(kubectl)
    [[ -n "$CURL" ]] || missing_tools+=(curl)
    if (( ${#missing_tools[@]} > 0 )); then
        fail "$EXIT_DEPENDENCY" "Required local tools are missing: ${missing_tools[*]}. Install Minikube, kubectl, and curl; no remote target will be used."
    fi

    echo "=== Iskaar Minikube Setup ==="
    print_configuration
    echo ""

    verify_target_before_mutation
    ensure_profile_running
    ensure_ingress
    ensure_cert_manager
    ensure_cluster_issuer
    setup_access
    write_access_output

    echo ""
    echo "=== Minikube setup complete ==="
    print_access_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
