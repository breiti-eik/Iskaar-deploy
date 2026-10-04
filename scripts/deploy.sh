#!/usr/bin/env bash
set -euo pipefail

# Secret values are deliberately never emitted by shell tracing. This also
# protects invocations started with `bash -x deploy.sh`.
set +x

# =============================================================================
# Iskaar Deploy Script
# Orchestrates: Build ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ Push ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚¢ÃƒÂ¢Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ Rollout ÃƒÆ’Ã†â€™ÃƒÆ’Ã‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ Smoke-Test for the Iskaar project
# Usage: ./deploy.sh <environment> [--deploy <true|false>] [--monitoring <true|false>] [--tag <image-tag>] [--dry-run] [--skip-smoke]
# =============================================================================

# --- Configuration Variables -------------------------------------------------

# An explicitly empty REGISTRY selects the Minikube Docker daemon. An unset
# variable keeps the documented local-registry default for backwards
# compatibility with existing local registry setups.
REGISTRY="${REGISTRY-localhost:5000}"
NAMESPACE="${NAMESPACE:-iskaar}"
BACKEND_IMAGE="${BACKEND_IMAGE:-iskaar-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-iskaar-frontend}"
HELM_CHART_PATH="${HELM_CHART_PATH:-helm/iskaar}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
MINIKUBE_CONTEXT="${MINIKUBE_CONTEXT:-${MINIKUBE_PROFILE}}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
ACCESS_MODE="${ACCESS_MODE:-auto}"
MINIKUBE_START_TIMEOUT="${MINIKUBE_START_TIMEOUT:-180}"
INGRESS_TIMEOUT="${INGRESS_TIMEOUT:-120}"
CERTIFICATE_TIMEOUT="${CERTIFICATE_TIMEOUT:-120}"
CLUSTER_ISSUER_TIMEOUT="${CLUSTER_ISSUER_TIMEOUT:-60}"
ACCESS_TIMEOUT="${ACCESS_TIMEOUT:-60}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-60}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.17.2}"
BACKEND_CONTEXT="${BACKEND_CONTEXT:-../iskaarBE/iskaar-be}"
FRONTEND_CONTEXT="${FRONTEND_CONTEXT:-../iskaarFE/iskaar-frontend}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MONITORING_PATH="${MONITORING_PATH:-${REPO_ROOT}/k8s/monitoring}"
DEPLOY_NAMESPACE="iskaar"
POSTGRES_SECRET_NAME="postgres-credentials"
POSTGRES_SECRET_FILE="${POSTGRES_SECRET_FILE:-${REPO_ROOT}/secrets/postgres.env}"
READINESS_VALIDATOR="${READINESS_VALIDATOR:-${SCRIPT_DIR}/validate-readiness.sh}"
MINIKUBE_SETUP_SCRIPT="${MINIKUBE_SETUP_SCRIPT:-${SCRIPT_DIR}/minikube-setup.sh}"
BASH_BIN="${BASH:-bash}"

# --- Runtime State -----------------------------------------------------------

ENVIRONMENT=""
TAG_OVERRIDE=""
DEPLOY=false
MONITORING=false
DRY_RUN=false
SKIP_SMOKE=false
IMAGE_TAG=""
PRIMARY_TAG=""
USE_REGISTRY=true
# Normalized image strategy used by Docker builds and every Helm invocation.
# IMAGE_REGISTRY is empty only when the verified Minikube Docker daemon is used.
IMAGE_REGISTRY=""
IMAGE_PULL_POLICY=""
BACKEND_IMAGE_REFERENCE=""
FRONTEND_IMAGE_REFERENCE=""
LOCAL_POSTGRES_DB=""
LOCAL_POSTGRES_USER=""
LOCAL_POSTGRES_PASSWORD=""
LOCAL_SECRET_SOURCE=""
SECRET_INPUT_FILE=""
DEPLOY_ACCESS_OUTPUT_FILE=""
DEPLOY_ACCESS_PID_FILE=""
DEPLOY_ACCESS_PID=""
EFFECTIVE_HTTP_URL=""
EFFECTIVE_HTTPS_URL=""
SMOKE_BACKEND_URL=""
SMOKE_FRONTEND_URL=""
HELM_RELEASE_NAME="iskaar"
PREVIOUS_HELM_REVISION=""
HAS_PREVIOUS_HELM_REVISION=false
RELEASE_MUTATION_STARTED=false
ROLLBACK_IN_PROGRESS=false
ROLLBACK_ATTEMPTED=false

# --- Helper Functions --------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <environment> [options]

Deploy the Iskaar application to a Kubernetes cluster.
The default mode validates deployment readiness without enabling deployment.

Arguments:
  environment          Target environment: dev, stage, or prod

Options:
  --deploy <true|false>  Select readiness or local Minikube deployment (default: false)
  --monitoring <true|false>
                         Include the optional monitoring stack (default: false)
  --tag <image-tag>      Override the image tag (default: determined from git)
  --dry-run              Compatibility alias for readiness mode (no mutation)
  --skip-smoke           Skip post-deployment smoke tests
  -h, --help             Show this help message

Examples:
  $(basename "$0") dev
  $(basename "$0") stage --tag v1.0.0
  $(basename "$0") prod --tag v2.1.0 --dry-run
  $(basename "$0") dev --deploy true --monitoring false
  $(basename "$0") dev --skip-smoke

Configuration (environment variables):
  REGISTRY             Container registry address (default: localhost:5000)
  NAMESPACE            Kubernetes namespace (default: iskaar)
  BACKEND_IMAGE        Backend image name (default: iskaar-backend)
  FRONTEND_IMAGE       Frontend image name (default: iskaar-frontend)
  HELM_CHART_PATH      Path to Helm chart (default: helm/iskaar)
  MINIKUBE_PROFILE     Local Minikube profile (default: minikube)
  MINIKUBE_CONTEXT     Expected local Kubernetes context (default: profile)
  MINIKUBE_DRIVER      Local Minikube driver (default: docker)
  KUBECONFIG           Optional local kubeconfig path (never printed)
  ACCESS_MODE           Access mode: auto, tunnel, or port-forward (default: auto)
  MINIKUBE_START_TIMEOUT  Minikube/API setup timeout (default: 180)
  INGRESS_TIMEOUT      Ingress addon/controller timeout (default: 120)
  CERTIFICATE_TIMEOUT  cert-manager timeout (default: 120)
  CLUSTER_ISSUER_TIMEOUT ClusterIssuer timeout (default: 60)
  ACCESS_TIMEOUT       Tunnel/port-forward timeout (default: 60)
  SMOKE_TIMEOUT        Timeout for each smoke-test request (default: 60)
  CERT_MANAGER_VERSION Pinned cert-manager version (default: v1.17.2)
  MINIKUBE_SETUP_SCRIPT Minikube setup helper path (default: scripts/minikube-setup.sh)
  BUILD_TIMEOUT        Max build duration in seconds (default: 300)
  ROLLOUT_TIMEOUT      Max rollout duration in seconds (default: 120)
  BACKEND_CONTEXT      Docker build context for backend (default: ../iskaarBE/iskaar-be)
  FRONTEND_CONTEXT     Docker build context for frontend (default: ../iskaarFE/iskaar-frontend)
  POSTGRES_SECRET_FILE Local secret env file below secrets/ (default: secrets/postgres.env)
  READINESS_VALIDATOR  Readiness validator path (default: scripts/validate-readiness.sh)
EOF
}

# Validate boolean CLI values without accepting aliases or coercion.
validate_boolean_option() {
    local option_name="$1"
    local option_value="$2"

    case "$option_value" in
        true|false)
            ;;
        *)
            echo "Error: ${option_name} accepts only the exact values 'true' or 'false' (received '${option_value}')." >&2
            echo "Valid values: true, false" >&2
            exit 1
            ;;
    esac
}

# Reject omitted option values before any external command can be executed.
require_boolean_option_value() {
    local option_name="$1"
    local option_value="${2:-}"

    if [[ -z "$option_value" || "$option_value" == --* ]]; then
        echo "Error: ${option_name} requires a value: true or false." >&2
        echo "Valid values: true, false" >&2
        exit 1
    fi
}

# Print the stable mode header before any preflight or deployment command.
print_mode_summary() {
    if [[ "$DEPLOY" == true ]]; then
        echo "Mode: DEPLOY (deploy=true)"
    else
        echo "Mode: READINESS (deploy=false)"
    fi
    echo "Environment: ${ENVIRONMENT}"
    echo "Minikube profile: ${MINIKUBE_PROFILE}"

    if [[ "$DEPLOY" == true ]]; then
        echo "Target context: ${MINIKUBE_PROFILE}"
    else
        echo "Minikube target: not contacted"
    fi

    echo "Monitoring: ${MONITORING}"
    if [[ "$DEPLOY" == true ]]; then
        echo "Cluster mutations: enabled for local Minikube only"
    else
        echo "Cluster mutations: disabled"
    fi
}

validate_prerequisites() {
    local missing=()

    for cmd in git docker helm kubectl minikube curl; do
        if ! command -v "$cmd" &>/dev/null && ! command -v "${cmd}.exe" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "[DRY-RUN] Warning: Missing tools (would be required for actual deploy): ${missing[*]}"
        else
            echo "Error: Missing required tools: ${missing[*]}" >&2
            echo "Please install the missing tools and try again." >&2
            exit 1
        fi
    fi
}

# Resolve command: prefer .exe on Windows/WSL (tools configured there), fall back to native
resolve_cmd() {
    local cmd="$1"
    if command -v "${cmd}.exe" &>/dev/null; then
        echo "${cmd}.exe"
    elif command -v "$cmd" &>/dev/null; then
        echo "$cmd"
    else
        echo "$cmd"
    fi
}

HELM=$(resolve_cmd helm)
KUBECTL=$(resolve_cmd kubectl)
MINIKUBE=$(resolve_cmd minikube)
DOCKER=$(resolve_cmd docker)
CURL=$(resolve_cmd curl)

# Wrapper for command execution: prints instead of running in dry-run mode.
# Usage: run_cmd docker push myimage:latest
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] $*"
    else
        if ! "$@"; then
            echo "Error: Command failed: $*" >&2
            exit 1
        fi
    fi
}

# --- Local Secret Handling ---------------------------------------------------

# Never include a credential value in diagnostics. Callers only pass field names
# or phase descriptions to this helper.
secret_preflight_error() {
    echo "Error: Local PostgreSQL secret preflight failed: $*" >&2
    return 1
}

# Resolve a local env file below the repository's git-ignored secrets/ tree.
# The path may be overridden for local tooling, but it can never leave that
# directory and symlinked files are rejected.
resolve_local_secret_file() {
    local configured_file="${POSTGRES_SECRET_FILE}"
    local secrets_directory="${REPO_ROOT}/secrets"
    local candidate="${configured_file}"
    local real_secrets_directory
    local real_parent

    if [[ "$candidate" != /* ]]; then
        candidate="${REPO_ROOT}/${candidate}"
    fi

    if [[ "$candidate" != "${secrets_directory}"/* ]]; then
        secret_preflight_error "POSTGRES_SECRET_FILE must point below the local secrets/ directory."
        return 1
    fi
    if [[ ! -d "$secrets_directory" || ! -f "$candidate" || -L "$candidate" ]]; then
        secret_preflight_error "no usable local secret file was found below secrets/."
        return 1
    fi

    real_secrets_directory="$(cd -- "$secrets_directory" && pwd -P)"
    real_parent="$(cd -- "$(dirname -- "$candidate")" && pwd -P)"
    case "${real_parent}/" in
        "${real_secrets_directory}/"*)
            ;;
        *)
            secret_preflight_error "POSTGRES_SECRET_FILE resolves outside the local secrets/ directory."
            return 1
            ;;
    esac

    printf '%s\n' "$candidate"
}

# Remove optional matching quotes from a local env-file value without sourcing
# or evaluating the file. The value is printed only into command substitution,
# never to the deployment log.
strip_env_file_quotes() {
    local value="$1"
    if [[ "${#value}" -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${#value}" -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

# Parse only the three supported keys. In particular, do not source the file:
# local secret files are data, not shell code.
read_local_secret_file() {
    local secret_file="$1"
    local line=""
    local key=""
    local value=""
    local db_seen=false
    local user_seen=false
    local password_seen=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        if [[ "$line" != *=* ]]; then
            secret_preflight_error "local secret file contains a malformed entry."
            return 1
        fi

        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "export "* ]]; then
            key="${key#export }"
        fi

        case "$key" in
            POSTGRES_DB)
                if [[ "$db_seen" == true ]]; then
                    secret_preflight_error "local secret file contains a duplicate POSTGRES_DB entry."
                    return 1
                fi
                LOCAL_POSTGRES_DB="$(strip_env_file_quotes "$value")"
                db_seen=true
                ;;
            POSTGRES_USER)
                if [[ "$user_seen" == true ]]; then
                    secret_preflight_error "local secret file contains a duplicate POSTGRES_USER entry."
                    return 1
                fi
                LOCAL_POSTGRES_USER="$(strip_env_file_quotes "$value")"
                user_seen=true
                ;;
            POSTGRES_PASSWORD)
                if [[ "$password_seen" == true ]]; then
                    secret_preflight_error "local secret file contains a duplicate POSTGRES_PASSWORD entry."
                    return 1
                fi
                LOCAL_POSTGRES_PASSWORD="$(strip_env_file_quotes "$value")"
                password_seen=true
                ;;
            *)
                secret_preflight_error "local secret file contains an unsupported entry."
                return 1
                ;;
        esac
    done < "$secret_file"

    local missing_fields=()
    [[ "$db_seen" == true ]] || missing_fields+=(POSTGRES_DB)
    [[ "$user_seen" == true ]] || missing_fields+=(POSTGRES_USER)
    [[ "$password_seen" == true ]] || missing_fields+=(POSTGRES_PASSWORD)
    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        secret_preflight_error "local secret file is incomplete; required keys: ${missing_fields[*]}."
        return 1
    fi
}

# Validate values without ever printing them. The manifest's base64 placeholder
# and its decoded value are both rejected as productive credentials.
validate_local_postgres_values() {
    local field_name
    local field_value
    local field_names=(POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD)
    local field_values=("$LOCAL_POSTGRES_DB" "$LOCAL_POSTGRES_USER" "$LOCAL_POSTGRES_PASSWORD")
    local index

    for index in "${!field_names[@]}"; do
        field_name="${field_names[$index]}"
        field_value="${field_values[$index]}"
        if [[ -z "$field_value" ]]; then
            secret_preflight_error "${field_name} is missing or empty."
            return 1
        fi
        case "$field_value" in
            iskaar|aXNrYWFy)
                secret_preflight_error "${field_name} contains a known placeholder value."
                return 1
                ;;
            *$'\n'*|*$'\r'*)
                secret_preflight_error "${field_name} contains an unsupported line break."
                return 1
                ;;
        esac
    done
}

# Read credentials only in deploy=true mode. Environment variables are an
# all-or-nothing source; partial environment input is not mixed with a file.
load_local_postgres_credentials() {
    [[ "$DEPLOY" == true ]] || return 0

    local environment_value_count=0
    local secret_file
    [[ -n "${POSTGRES_DB+x}" ]] && environment_value_count=$((environment_value_count + 1))
    [[ -n "${POSTGRES_USER+x}" ]] && environment_value_count=$((environment_value_count + 1))
    [[ -n "${POSTGRES_PASSWORD+x}" ]] && environment_value_count=$((environment_value_count + 1))

    if (( environment_value_count > 0 )); then
        if [[ -z "${POSTGRES_DB+x}" || -z "${POSTGRES_USER+x}" || -z "${POSTGRES_PASSWORD+x}" ]]; then
            secret_preflight_error "POSTGRES_DB, POSTGRES_USER and POSTGRES_PASSWORD must be provided together."
            return 1
        fi
        LOCAL_POSTGRES_DB="${POSTGRES_DB-}"
        LOCAL_POSTGRES_USER="${POSTGRES_USER-}"
        LOCAL_POSTGRES_PASSWORD="${POSTGRES_PASSWORD-}"
        LOCAL_SECRET_SOURCE="environment"
    else
        secret_file="$(resolve_local_secret_file)" || return $?
        read_local_secret_file "$secret_file" || return $?
        LOCAL_SECRET_SOURCE="local file"
    fi

    validate_local_postgres_values || return $?
    echo "[DEPLOY] Local PostgreSQL secret preflight passed (source=${LOCAL_SECRET_SOURCE}, secret=${POSTGRES_SECRET_NAME}, namespace=${DEPLOY_NAMESPACE})."
}

cleanup_local_secret_input_file() {
    if [[ -n "${SECRET_INPUT_FILE:-}" ]]; then
        rm -f -- "$SECRET_INPUT_FILE" 2>/dev/null || true
        SECRET_INPUT_FILE=""
    fi
}

# Materialize validated values only after the namespace phase has succeeded.
# mktemp creates a 0600 file; the file path, never a credential, is passed to
# kubectl via --from-env-file.
write_local_secret_input_file() {
    local previous_umask
    local temporary_file

    previous_umask="$(umask)"
    umask 077
    if ! temporary_file="$(mktemp "${TMPDIR:-/tmp}/iskaar-postgres-secret.XXXXXX")"; then
        umask "$previous_umask"
        secret_preflight_error "could not create a secure temporary secret input."
        return 1
    fi
    umask "$previous_umask"

    if ! {
        printf 'POSTGRES_DB=%s\n' "$LOCAL_POSTGRES_DB"
        printf 'POSTGRES_USER=%s\n' "$LOCAL_POSTGRES_USER"
        printf 'POSTGRES_PASSWORD=%s\n' "$LOCAL_POSTGRES_PASSWORD"
    } > "$temporary_file"; then
        rm -f -- "$temporary_file" 2>/dev/null || true
        secret_preflight_error "could not write the secure temporary secret input."
        return 1
    fi

    SECRET_INPUT_FILE=""
}

# Namespace creation is idempotent and deliberately precedes secret creation.
# It is called only from the deploy=true path after all read-only safety gates.
ensure_deploy_namespace() {
    [[ "$DEPLOY" == true ]] || return 0

    local status=0
    echo "[DEPLOY] Namespace phase: ${DEPLOY_NAMESPACE}."
    "$KUBECTL" --context "$MINIKUBE_CONTEXT" create namespace "$DEPLOY_NAMESPACE" --dry-run=client -o yaml \
        | "$KUBECTL" --context "$MINIKUBE_CONTEXT" apply -f - \
        || status=$?

    if (( status != 0 )); then
        echo "Error: Namespace phase failed for the local deployment target (exit code ${status})." >&2
        return "$status"
    fi
    echo "[DEPLOY] Namespace phase completed."
}

# Create/update only the fixed local credential Secret. No secret value is part
# of a command argument, Helm value, diagnostic, or workflow summary.
create_local_postgres_secret() {
    [[ "$DEPLOY" == true ]] || return 0

    write_local_secret_input_file || return $?

    local status=0
    echo "[DEPLOY] Local secret phase: ${POSTGRES_SECRET_NAME} in ${DEPLOY_NAMESPACE}."
    "$KUBECTL" --context "$MINIKUBE_CONTEXT" --namespace "$DEPLOY_NAMESPACE" \
        create secret generic "$POSTGRES_SECRET_NAME" \
        --from-env-file="$SECRET_INPUT_FILE" \
        --dry-run=client -o yaml \
        | "$KUBECTL" --context "$MINIKUBE_CONTEXT" apply -f - \
        || status=$?
    cleanup_local_secret_input_file

    if (( status != 0 )); then
        echo "Error: Local secret phase failed for ${POSTGRES_SECRET_NAME} (exit code ${status})." >&2
        return "$status"
    fi
    echo "[DEPLOY] Local secret phase completed."
}

# --- Readiness Integration ---------------------------------------------------

# Run the complete non-mutating readiness pipeline. This function deliberately
# does not call any Minikube, registry publication, or Helm mutation helper.
run_readiness_validation() {
    local validator="${READINESS_VALIDATOR}"
    local status=0
    local -a validator_args=(
        "${ENVIRONMENT}"
        --deploy false
        --monitoring "${MONITORING}"
    )

    if [[ -n "${TAG_OVERRIDE}" ]]; then
        validator_args+=(--tag "${TAG_OVERRIDE}")
    fi

    if [[ ! -f "${validator}" ]]; then
        echo "Error: Readiness phase failed: validator not found at '${validator}'." >&2
        echo "No Minikube, registry, Helm, or cluster mutation was started." >&2
        return 1
    fi

    echo "[READINESS] Starting validator."
    if (
        unset POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_SECRET_FILE
        export REGISTRY NAMESPACE BACKEND_IMAGE FRONTEND_IMAGE BUILD_TIMEOUT
        export BACKEND_CONTEXT FRONTEND_CONTEXT HELM_CHART_PATH
        "${BASH_BIN}" "${validator}" "${validator_args[@]}"
    ); then
        status=0
    else
        status=$?
    fi

    if (( status != 0 )); then
        echo "Error: Readiness phase failed (validator exit code ${status})." >&2
        echo "No Minikube, registry, Helm, or cluster mutation was started." >&2
        return "${status}"
    fi

    echo "Readiness validation completed successfully."
    echo "Cluster mutations: none (readiness mode)"
    return 0
}

# --- Minikube Safety Guard and Setup -----------------------------------------

# Keep the registry boundary local before the setup helper can perform any
# Minikube or Kubernetes mutation. Empty REGISTRY intentionally selects the
# Minikube Docker daemon.
validate_local_registry_boundary() {
    local registry="${REGISTRY:-}"
    local authority
    local host

    if [[ -z "$registry" ]]; then
        echo "Registry boundary: Minikube Docker daemon"
        return 0
    fi

    if [[ "$registry" == *'://'* || "$registry" == *'@'* || "$registry" == *[[:space:]]* ]]; then
        echo "Error: REGISTRY must be a local host[:port][/path] without a URL scheme, credentials, or whitespace." >&2
        return 1
    fi

    authority="${registry%%/*}"
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority%%\]*}"
        host="${host#\[}"
    else
        host="${authority%%:*}"
    fi

    case "$host" in
        localhost|host.docker.internal|127.*|::1|registry|registry.*.svc.cluster.local)
            echo "Registry boundary: local (${host})"
            return 0
            ;;
        *)
            echo "Error: Remote registry '${host:-unknown}' is not allowed for local Minikube deployment." >&2
            echo "Use localhost, a loopback address, host.docker.internal, a Minikube registry service, or an empty REGISTRY." >&2
            return 1
            ;;
    esac
}

validate_positive_setup_timeout() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: ${name} must be a positive integer (received '${value}')." >&2
        return 1
    fi
}

# Validate all deploy-only configuration before invoking the helper. The
# helper performs the read-only profile/context/server verification itself
# before its first mutating operation.
validate_deploy_safety_configuration() {
    [[ "$DEPLOY" == true ]] || return 0

    if [[ "$ENVIRONMENT" != "dev" ]]; then
        echo "Error: deploy=true is restricted to the local dev Minikube target." >&2
        return 1
    fi
    if [[ "$NAMESPACE" != "$DEPLOY_NAMESPACE" ]]; then
        echo "Error: deploy=true requires the fixed namespace '${DEPLOY_NAMESPACE}'." >&2
        return 1
    fi
    if [[ ! "$MINIKUBE_PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "Error: MINIKUBE_PROFILE contains unsupported characters." >&2
        return 1
    fi
    if [[ ! "$MINIKUBE_CONTEXT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "Error: MINIKUBE_CONTEXT contains unsupported characters." >&2
        return 1
    fi
    case "$MINIKUBE_DRIVER" in
        docker|podman|virtualbox|hyperv|hyperkit|kvm2|qemu2|vfkit|none)
            ;;
        *)
            echo "Error: MINIKUBE_DRIVER '${MINIKUBE_DRIVER}' is not an accepted local driver." >&2
            return 1
            ;;
    esac
    case "$ACCESS_MODE" in
        auto|tunnel|port-forward)
            ;;
        *)
            echo "Error: ACCESS_MODE must be exactly auto, tunnel, or port-forward." >&2
            return 1
            ;;
    esac

    validate_positive_setup_timeout MINIKUBE_START_TIMEOUT "$MINIKUBE_START_TIMEOUT" || return $?
    validate_positive_setup_timeout INGRESS_TIMEOUT "$INGRESS_TIMEOUT" || return $?
    validate_positive_setup_timeout CERTIFICATE_TIMEOUT "$CERTIFICATE_TIMEOUT" || return $?
    validate_positive_setup_timeout CLUSTER_ISSUER_TIMEOUT "$CLUSTER_ISSUER_TIMEOUT" || return $?
    validate_positive_setup_timeout ACCESS_TIMEOUT "$ACCESS_TIMEOUT" || return $?
    validate_positive_setup_timeout SMOKE_TIMEOUT "$SMOKE_TIMEOUT" || return $?

    if [[ ! -f "$MINIKUBE_SETUP_SCRIPT" ]]; then
        echo "Error: Minikube setup helper not found at '${MINIKUBE_SETUP_SCRIPT}'." >&2
        return 1
    fi

    # Do not print or parse kubeconfig contents. The setup helper validates the
    # configured file and then verifies that its selected server is local.
    if [[ -n "${KUBECONFIG:-}" && "${KUBECONFIG}" == *'://'* ]]; then
        echo "Error: KUBECONFIG must reference a local kubeconfig file, not a URL." >&2
        return 1
    fi

    validate_local_registry_boundary
}

# Invoke the dedicated setup helper only for deploy=true. All values are
# passed as separate arguments; no shell evaluation is used and no secret
# values are part of this argument list. The access process is deliberately
# kept alive for the later smoke phase and cleaned by the deployment trap.
run_minikube_setup() {
    local status=0
    local -a setup_args=(
        --profile "$MINIKUBE_PROFILE"
        --driver "$MINIKUBE_DRIVER"
        --context "$MINIKUBE_CONTEXT"
        "--registry=${REGISTRY}"
        --access-mode "$ACCESS_MODE"
        --start-timeout "$MINIKUBE_START_TIMEOUT"
        --ingress-timeout "$INGRESS_TIMEOUT"
        --certificate-timeout "$CERTIFICATE_TIMEOUT"
        --cluster-issuer-timeout "$CLUSTER_ISSUER_TIMEOUT"
        --access-timeout "$ACCESS_TIMEOUT"
        --cert-manager-version "$CERT_MANAGER_VERSION"
    )

    if [[ -n "${KUBECONFIG:-}" ]]; then
        setup_args+=(--kubeconfig "$KUBECONFIG")
    fi

    if [[ "$SKIP_SMOKE" != true ]]; then
        DEPLOY_ACCESS_OUTPUT_FILE="${TMPDIR:-/tmp}/iskaar-deploy-access-${BASHPID}.env"
        DEPLOY_ACCESS_PID_FILE="${TMPDIR:-/tmp}/iskaar-deploy-access-${BASHPID}.pid"
        rm -f -- "$DEPLOY_ACCESS_OUTPUT_FILE" "$DEPLOY_ACCESS_PID_FILE"
        setup_args+=(
            --output-file "$DEPLOY_ACCESS_OUTPUT_FILE"
            --pid-file "$DEPLOY_ACCESS_PID_FILE"
            --keep-access
        )
    fi

    echo "[DEPLOY] Starting local Minikube setup (profile=${MINIKUBE_PROFILE}, access-mode=${ACCESS_MODE})."
    if (
        export NAMESPACE
        "$BASH_BIN" "$MINIKUBE_SETUP_SCRIPT" "${setup_args[@]}"
    ); then
        if [[ "$SKIP_SMOKE" != true ]]; then
            read_access_output
        fi
        echo "[DEPLOY] Local Minikube setup completed."
        return 0
    else
        status=$?
    fi

    echo "Error: Local Minikube setup failed before application deployment (exit code ${status})." >&2
    return "$status"
}

# --- Core Functions (placeholders for tasks 7.2-7.5) -------------------------

# Ensure Minikube is running and registry addon is enabled
ensure_minikube_running() {
    echo "Checking Minikube status..."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] minikube status"
        echo "[DRY-RUN] minikube addons list | grep registry"
        return 0
    fi

    # Check if minikube is running for the already verified profile.
    if ! "$MINIKUBE" status --profile "$MINIKUBE_PROFILE" --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
        echo "Minikube profile '${MINIKUBE_PROFILE}' is not running. Starting it..."
        if ! "$MINIKUBE" start --profile "$MINIKUBE_PROFILE" --driver "$MINIKUBE_DRIVER"; then
            echo "Error: Failed to start Minikube profile '${MINIKUBE_PROFILE}'." >&2
            exit 1
        fi
        echo "Minikube profile '${MINIKUBE_PROFILE}' started successfully."
        # Wait for cluster to be ready
        echo "Waiting for cluster to be ready..."
        sleep 5
        if ! "$KUBECTL" --context "$MINIKUBE_CONTEXT" cluster-info --request-timeout=30s >/dev/null 2>&1; then
            echo "Error: Cluster '${MINIKUBE_CONTEXT}' not ready after Minikube start." >&2
            exit 1
        fi
    else
        echo "Minikube profile '${MINIKUBE_PROFILE}' is running."
    fi

    # Check if registry addon is enabled (optional — fallback to docker-env if not)
    if ! "$MINIKUBE" addons list --profile "$MINIKUBE_PROFILE" 2>/dev/null | grep -E "registry\s" | grep -q "enabled"; then
        echo "Registry addon not enabled (will use Minikube Docker daemon as fallback)."
    fi
}

# Task 7.2: Tag determination and semver validation
determine_tag() {
    if [ -n "$TAG_OVERRIDE" ]; then
        # Manual override: use directly
        IMAGE_TAG="$TAG_OVERRIDE"
        # Validate semver if it looks like a semver tag (starts with v)
        if echo "$TAG_OVERRIDE" | grep -qE '^v'; then
            validate_semver "$TAG_OVERRIDE"
            PRIMARY_TAG="$TAG_OVERRIDE"
        fi
    elif SEMVER=$(git describe --tags --abbrev=0 2>/dev/null); then
        # Git tag found: Semver + SHA suffix
        validate_semver "$SEMVER"
        SHA=$(git rev-parse --short HEAD)
        IMAGE_TAG="${SEMVER}-${SHA}"   # e.g. v1.0.0-abc1234
        PRIMARY_TAG="$SEMVER"          # e.g. v1.0.0
    else
        # Fallback: only Git SHA
        IMAGE_TAG=$(git rev-parse --short HEAD)
        echo "[WARNING] No git tag found. Using Git SHA as fallback: $IMAGE_TAG" >&2
    fi

    echo "Image tag: $IMAGE_TAG"
    if [ -n "$PRIMARY_TAG" ]; then
        echo "Primary tag: $PRIMARY_TAG"
    fi
}

# Task 7.2: Semver format validation
validate_semver() {
    local tag="$1"
    if ! echo "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Error: Git tag '$tag' is not a valid semver tag (expected vMAJOR.MINOR.PATCH)" >&2
        exit 1
    fi
}

# --- Local image strategy ----------------------------------------------------

# Select the verified Minikube Docker daemon. This changes only the Docker
# client environment; it does not push to or contact a remote registry.
use_minikube_docker_daemon() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] minikube docker-env --profile ${MINIKUBE_PROFILE} --shell bash"
        USE_REGISTRY=false
        REGISTRY=""
        return 0
    fi

    local docker_env=""
    if ! docker_env="$("$MINIKUBE" docker-env --profile "$MINIKUBE_PROFILE" --shell bash 2>/dev/null)"; then
        echo "Error: Could not configure the Docker client for Minikube profile '${MINIKUBE_PROFILE}'." >&2
        return 1
    fi

    # `minikube docker-env` emits local Docker-client exports. They contain no
    # application credentials and are evaluated only after the Minikube target
    # has passed the safety guard.
    if [[ -n "$docker_env" ]]; then
        eval "$docker_env"
    fi

    USE_REGISTRY=false
    REGISTRY=""
    echo "Image target: Minikube Docker daemon (registry=empty, imagePullPolicy=Never)."
}

# Validate and probe only local registries. A configured but unavailable local
# registry may fall back to the already verified Minikube Docker daemon; a
# remote registry is rejected by validate_local_registry_boundary before this
# function can select it.
check_registry() {
    [[ "$DEPLOY" == true ]] || return 0

    validate_local_registry_boundary || return $?

    # An explicitly empty registry is the unambiguous daemon strategy. Do not
    # probe localhost, discover a registry service, or issue a push in this
    # mode.
    if [[ -z "$REGISTRY" ]]; then
        use_minikube_docker_daemon
        return $?
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] local registry probe: http://${REGISTRY%/}/v2/"
        USE_REGISTRY=true
        return 0
    fi

    local registry_url="${REGISTRY%/}"
    if command -v "$CURL" >/dev/null 2>&1 && \
        "$CURL" -fsS --max-time 5 "http://${registry_url}/v2/" >/dev/null 2>&1; then
        USE_REGISTRY=true
        echo "Image target: verified local registry ${registry_url} (imagePullPolicy=IfNotPresent)."
        return 0
    fi

    # Preserve the existing Minikube registry-service fallback, but only use
    # the service URL after a successful local probe. This never authorizes a
    # remote registry and keeps the image reference aligned with the result.
    local mk_port=""
    mk_port="$("$MINIKUBE" service registry -n kube-system --url --profile "$MINIKUBE_PROFILE" 2>/dev/null \
        | sed -n 's/.*:\([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [[ -n "$mk_port" ]] && command -v "$CURL" >/dev/null 2>&1 && \
        "$CURL" -fsS --max-time 5 "http://localhost:${mk_port}/v2/" >/dev/null 2>&1; then
        REGISTRY="localhost:${mk_port}"
        USE_REGISTRY=true
        echo "Image target: verified local Minikube registry ${REGISTRY} (imagePullPolicy=IfNotPresent)."
        return 0
    fi

    echo "Local registry '${registry_url}' is unavailable; using the verified Minikube Docker daemon instead."
    use_minikube_docker_daemon
}

# Build the exact image reference used by both Docker and Helm. An empty
# IMAGE_REGISTRY deliberately produces a daemon-local reference without a
# leading slash.
image_reference_for_tag() {
    local image_name="$1"
    local image_tag="$2"

    if [[ -n "$IMAGE_REGISTRY" ]]; then
        printf '%s/%s:%s\n' "${IMAGE_REGISTRY%/}" "$image_name" "$image_tag"
    else
        printf '%s:%s\n' "$image_name" "$image_tag"
    fi
}

image_reference() {
    image_reference_for_tag "$1" "$IMAGE_TAG"
}

# Normalize the image strategy once after check_registry. The resulting
# values are the only image registry and pull-policy values passed to Helm.
configure_image_strategy() {
    [[ "$DEPLOY" == true ]] || return 0

    if [[ "$USE_REGISTRY" == true ]]; then
        if [[ -z "$REGISTRY" ]]; then
            echo "Error: Registry strategy selected without a local registry address." >&2
            return 1
        fi
        validate_local_registry_boundary || return $?
        IMAGE_REGISTRY="${REGISTRY%/}"
        IMAGE_PULL_POLICY="IfNotPresent"
    else
        IMAGE_REGISTRY=""
        IMAGE_PULL_POLICY="Never"
    fi

    BACKEND_IMAGE_REFERENCE="$(image_reference "$BACKEND_IMAGE")"
    FRONTEND_IMAGE_REFERENCE="$(image_reference "$FRONTEND_IMAGE")"
    echo "Image registry: ${IMAGE_REGISTRY:-<minikube-docker-daemon>}"
    echo "Image pull policy: ${IMAGE_PULL_POLICY}"
    echo "Backend image: ${BACKEND_IMAGE_REFERENCE}"
    echo "Frontend image: ${FRONTEND_IMAGE_REFERENCE}"
}

run_docker_build() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$BUILD_TIMEOUT" "$DOCKER" "$@"
    else
        "$DOCKER" "$@"
    fi
}

# Build Docker images in the selected local target. This function intentionally
# has no registry publication side effect.
build_images() {
    configure_image_strategy || return $?

    local be_tag="$BACKEND_IMAGE_REFERENCE"
    local fe_tag="$FRONTEND_IMAGE_REFERENCE"

    echo "Building backend image..."
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] docker build --tag ${be_tag} ${BACKEND_CONTEXT}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker tag ${be_tag} $(image_reference_for_tag "$BACKEND_IMAGE" "$PRIMARY_TAG")"
        fi
        echo "[DRY-RUN] docker build --tag ${fe_tag} ${FRONTEND_CONTEXT}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker tag ${fe_tag} $(image_reference_for_tag "$FRONTEND_IMAGE" "$PRIMARY_TAG")"
        fi
        return 0
    fi

    if ! run_docker_build build --tag "$be_tag" "$BACKEND_CONTEXT"; then
        echo "Error: Backend image build failed for the local image target." >&2
        return 1
    fi

    if [[ -n "${PRIMARY_TAG}" ]]; then
        "$DOCKER" tag "$be_tag" "$(image_reference_for_tag "$BACKEND_IMAGE" "$PRIMARY_TAG")"
    fi

    echo "Building frontend image..."
    if ! run_docker_build build --tag "$fe_tag" "$FRONTEND_CONTEXT"; then
        echo "Error: Frontend image build failed for the local image target." >&2
        return 1
    fi

    if [[ -n "${PRIMARY_TAG}" ]]; then
        "$DOCKER" tag "$fe_tag" "$(image_reference_for_tag "$FRONTEND_IMAGE" "$PRIMARY_TAG")"
    fi

    verify_local_images
    echo "Images built and verified locally."
}

# Verify the tags that will be referenced by Kubernetes before any Helm
# mutation. Docker output is discarded so only non-sensitive image metadata can
# affect the result report.
verify_local_image() {
    local image_reference_value="$1"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] docker image inspect ${image_reference_value}"
        return 0
    fi

    if "$DOCKER" image inspect "$image_reference_value" >/dev/null 2>&1; then
        return 0
    fi
    if "$DOCKER" image ls --format '{{.Repository}}:{{.Tag}}' "$image_reference_value" 2>/dev/null \
        | grep -Fxq -- "$image_reference_value"; then
        return 0
    fi

    echo "Error: Local Docker image is missing: ${image_reference_value}." >&2
    return 1
}

verify_local_images() {
    verify_local_image "$BACKEND_IMAGE_REFERENCE" || return $?
    verify_local_image "$FRONTEND_IMAGE_REFERENCE" || return $?
}

# Publish only to the verified local registry. The guard is intentionally
# defensive: even an accidental caller from Readiness_Mode cannot execute a
# docker push.
push_images() {
    if [[ "$DEPLOY" != true ]]; then
        echo "Skipping image push (readiness mode forbids registry publication)."
        return 0
    fi
    if [[ "$USE_REGISTRY" == false ]]; then
        echo "Skipping image push (images are in the Minikube Docker daemon)."
        return 0
    fi
    if [[ -z "$IMAGE_REGISTRY" ]]; then
        echo "Error: Refusing image push without a verified local registry." >&2
        return 1
    fi
    validate_local_registry_boundary || return $?

    echo "Pushing images to verified local registry ${IMAGE_REGISTRY}..."
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] docker push ${BACKEND_IMAGE_REFERENCE}"
        echo "[DRY-RUN] docker push ${FRONTEND_IMAGE_REFERENCE}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker push $(image_reference_for_tag "$BACKEND_IMAGE" "$PRIMARY_TAG")"
            echo "[DRY-RUN] docker push $(image_reference_for_tag "$FRONTEND_IMAGE" "$PRIMARY_TAG")"
        fi
        return 0
    fi

    if ! "$DOCKER" push "$BACKEND_IMAGE_REFERENCE"; then
        echo "Error: Failed to push the backend image to the verified local registry." >&2
        return 1
    fi
    if ! "$DOCKER" push "$FRONTEND_IMAGE_REFERENCE"; then
        echo "Error: Failed to push the frontend image to the verified local registry." >&2
        return 1
    fi

    if [[ -n "${PRIMARY_TAG}" ]]; then
        if ! "$DOCKER" push "$(image_reference_for_tag "$BACKEND_IMAGE" "$PRIMARY_TAG")"; then
            echo "Error: Failed to push the backend primary image tag to the verified local registry." >&2
            return 1
        fi
        if ! "$DOCKER" push "$(image_reference_for_tag "$FRONTEND_IMAGE" "$PRIMARY_TAG")"; then
            echo "Error: Failed to push the frontend primary image tag to the verified local registry." >&2
            return 1
        fi
    fi

    echo "Images pushed to the verified local registry."
}

# --- Phased mutation, rollout gates and access cleanup -----------------------

# The setup helper writes only non-sensitive access metadata. Parse the file as
# data instead of sourcing it so a malformed helper output cannot execute shell
# code in this deployment process.
read_access_output() {
    if [[ ! -s "$DEPLOY_ACCESS_OUTPUT_FILE" ]]; then
        echo "Error: Access phase did not produce effective URLs for the smoke test." >&2
        return 1
    fi

    local line
    local key
    local value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            HTTP_URL)
                EFFECTIVE_HTTP_URL="$value"
                ;;
            HTTPS_URL)
                EFFECTIVE_HTTPS_URL="$value"
                ;;
            ACCESS_PID)
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    DEPLOY_ACCESS_PID="$value"
                fi
                ;;
            *)
                ;;
        esac
    done < "$DEPLOY_ACCESS_OUTPUT_FILE"

    case "${EFFECTIVE_HTTP_URL}" in
        http://*|https://*) ;;
        *) EFFECTIVE_HTTP_URL="" ;;
    esac
    case "${EFFECTIVE_HTTPS_URL}" in
        http://*|https://*) ;;
        *) EFFECTIVE_HTTPS_URL="" ;;
    esac

    if [[ -z "$EFFECTIVE_HTTP_URL" && -z "$EFFECTIVE_HTTPS_URL" ]]; then
        echo "Error: Access phase returned no usable HTTP or HTTPS URL." >&2
        return 1
    fi

    # Prefer HTTPS because the Ingress contract redirects HTTP to TLS. The
    # smoke script already uses curl -k for the local self-signed certificate.
    SMOKE_BACKEND_URL="${EFFECTIVE_HTTPS_URL:-$EFFECTIVE_HTTP_URL}"
    SMOKE_FRONTEND_URL="${EFFECTIVE_HTTPS_URL:-$EFFECTIVE_HTTP_URL}"
    echo "Effective smoke-test URLs captured from the local access phase."
}

stop_owned_process() {
    local process_id="${1:-}"
    local deadline

    if [[ ! "$process_id" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! kill -0 "$process_id" 2>/dev/null; then
        return 0
    fi

    kill -TERM "$process_id" 2>/dev/null || true
    deadline=$(( $(date +%s) + 5 ))
    while kill -0 "$process_id" 2>/dev/null && (( $(date +%s) < deadline )); do
        sleep 1
    done
    kill -KILL "$process_id" 2>/dev/null || true
    wait "$process_id" 2>/dev/null || true
}

# Cleanup is deliberately limited to processes and temporary metadata owned by
# this invocation. It never deletes Kubernetes resources, PVCs, or Secrets.
cleanup_deployment_processes() {
    local exit_code=$?
    local access_pid="${DEPLOY_ACCESS_PID:-}"

    if [[ -z "$access_pid" && -f "${DEPLOY_ACCESS_PID_FILE:-}" ]]; then
        read -r access_pid < "$DEPLOY_ACCESS_PID_FILE" || true
    fi
    stop_owned_process "$access_pid"
    DEPLOY_ACCESS_PID=""

    if [[ -n "${DEPLOY_ACCESS_OUTPUT_FILE:-}" ]]; then
        rm -f -- "$DEPLOY_ACCESS_OUTPUT_FILE" 2>/dev/null || true
    fi
    if [[ -n "${DEPLOY_ACCESS_PID_FILE:-}" ]]; then
        rm -f -- "$DEPLOY_ACCESS_PID_FILE" 2>/dev/null || true
    fi
    cleanup_local_secret_input_file
    return "$exit_code"
}

# Install one exit handler for both successful and failed deployment paths.
# This replaces the earlier secret-only trap so access processes are cleaned
# without weakening the Local_Secret cleanup contract.
trap cleanup_deployment_processes EXIT

run_deploy_phase() {
    local phase_name="$1"
    shift
    local status=0

    echo "[DEPLOY] ${phase_name} phase started."
    if "$@"; then
        echo "[DEPLOY] ${phase_name} phase completed."
        return 0
    else
        status=$?
    fi

    echo "Error: ${phase_name} phase failed (exit code ${status})." >&2
    if [[ "$DEPLOY" == true && "$RELEASE_MUTATION_STARTED" == true ]]; then
        handle_deployment_failure "${phase_name} phase" || true
    else
        print_core_diagnostics "${phase_name}"
    fi
    return "$status"
}

run_kubernetes_gate() {
    local gate_name="$1"
    shift
    local status=0

    echo "[DEPLOY] Gate: ${gate_name}."
    if "$KUBECTL" --context "$MINIKUBE_CONTEXT" "$@"; then
        echo "[DEPLOY] Gate passed: ${gate_name}."
        return 0
    else
        status=$?
    fi

    echo "Error: ${gate_name} gate failed (exit code ${status})." >&2
    return "$status"
}

print_core_diagnostics() {
    local resource_name="${1:-core resources}"
    echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' get pods -o wide" >&2
    echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' get events --sort-by=.lastTimestamp" >&2
    echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' describe ${resource_name}" >&2
}

# Read the latest revision without changing the cluster. The result is fixed
# before the first Helm release mutation and is used as the only rollback target.
detect_previous_helm_revision() {
    [[ "$DEPLOY" == true ]] || return 0

    local history_output=""
    local history_status=0
    history_output="$("$HELM" history "$HELM_RELEASE_NAME" \
        --namespace "$DEPLOY_NAMESPACE" \
        --max 1 \
        --output json 2>&1)" || history_status=$?

    if (( history_status != 0 )); then
        if grep -Eiq 'not found|release: not found' <<<"${history_output}"; then
            HAS_PREVIOUS_HELM_REVISION=false
            PREVIOUS_HELM_REVISION=""
            echo "[DEPLOY] No previous Helm revision found for release=${HELM_RELEASE_NAME}, namespace=${DEPLOY_NAMESPACE}; automatic rollback is unavailable for this run."
            return 0
        fi

        echo "Error: Could not inspect Helm release ${HELM_RELEASE_NAME} in namespace ${DEPLOY_NAMESPACE} before the first release mutation (exit code ${history_status})." >&2
        echo "Diagnostics: helm history ${HELM_RELEASE_NAME} --namespace ${DEPLOY_NAMESPACE} --max 1 --output json" >&2
        return "$history_status"
    fi

    local normalized_history
    local compact_history
    normalized_history="$(printf '%s' "${history_output}" | tr '\n' ' ')"
    compact_history="$(printf '%s' "${normalized_history}" | tr -d '[:space:]')"

    # Empty output is accepted for test doubles and older Helm wrappers that
    # report an absent release with a successful empty result.
    if [[ -z "${compact_history}" || "${compact_history}" == "[]" ]]; then
        HAS_PREVIOUS_HELM_REVISION=false
        PREVIOUS_HELM_REVISION=""
        echo "[DEPLOY] No previous Helm revision found for release=${HELM_RELEASE_NAME}, namespace=${DEPLOY_NAMESPACE}; automatic rollback is unavailable for this run."
        return 0
    fi

    PREVIOUS_HELM_REVISION="$(printf '%s\n' "${normalized_history}" \
        | sed -nE 's/.*"revision"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
        | head -n 1)"
    if [[ -z "${PREVIOUS_HELM_REVISION}" ]]; then
        # Keep compatibility with Helm's table output when JSON output is not
        # available, while still accepting only a numeric revision.
        PREVIOUS_HELM_REVISION="$(printf '%s\n' "${history_output}" \
            | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
    fi

    if [[ ! "${PREVIOUS_HELM_REVISION}" =~ ^[1-9][0-9]*$ ]]; then
        PREVIOUS_HELM_REVISION=""
        HAS_PREVIOUS_HELM_REVISION=false
        echo "Error: Helm history for release=${HELM_RELEASE_NAME}, namespace=${DEPLOY_NAMESPACE} did not contain a valid previous revision." >&2
        echo "Diagnostics: helm history ${HELM_RELEASE_NAME} --namespace ${DEPLOY_NAMESPACE} --max 1 --output json" >&2
        return 1
    fi

    HAS_PREVIOUS_HELM_REVISION=true
    echo "[DEPLOY] Previous Helm revision: ${PREVIOUS_HELM_REVISION} (release=${HELM_RELEASE_NAME}, namespace=${DEPLOY_NAMESPACE})."
}

report_partial_release_state() {
    echo "[DEPLOY] No previous Helm revision is available; the failed run may have left a partial release state." >&2
    echo "[DEPLOY] No PVC, Local_Secret, Secret, or data-volume cleanup is performed automatically." >&2
    echo "Diagnostics: helm history ${HELM_RELEASE_NAME} --namespace ${DEPLOY_NAMESPACE}" >&2
    echo "Diagnostics: helm status ${HELM_RELEASE_NAME} --namespace ${DEPLOY_NAMESPACE}" >&2
    echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' get pods,services,pvc,secrets,ingress" >&2
    print_core_diagnostics "deployment"
}

# Every Helm phase uses the same release and the same complete set of explicit
# mode, environment, image, Secret, namespace and component values. The
# component booleans are the only resource filter; deploy remains an auditable
# value and never hides resources during readiness rendering.
helm_upgrade_phase() {
    local phase_name="$1"
    local database_enabled="$2"
    local backend_enabled="$3"
    local frontend_enabled="$4"
    local tls_enabled="$5"
    local -a helm_args=(
        upgrade --install
        "$HELM_RELEASE_NAME"
        "$HELM_CHART_PATH"
        -f "${HELM_CHART_PATH}/values-${ENVIRONMENT}.yaml"
        --namespace "$DEPLOY_NAMESPACE"
        --create-namespace
        --wait
        "--timeout=${ROLLOUT_TIMEOUT}s"
        --set "deploy=true"
        --set "monitoring.enabled=${MONITORING}"
        --set-string "namespace=${DEPLOY_NAMESPACE}"
        --set-string "image.registry=${IMAGE_REGISTRY}"
        --set-string "image.backend.name=${BACKEND_IMAGE}"
        --set-string "image.frontend.name=${FRONTEND_IMAGE}"
        --set-string "image.backend.tag=${IMAGE_TAG}"
        --set-string "image.frontend.tag=${IMAGE_TAG}"
        --set "image.pullPolicy=${IMAGE_PULL_POLICY}"
        --set-string "postgresql.existingSecret=${POSTGRES_SECRET_NAME}"
        --set "postgresql.createPlaceholderSecret=false"
        --set "ingress.enabled=true"
        --set "components.database=${database_enabled}"
        --set "components.backend=${backend_enabled}"
        --set "components.frontend=${frontend_enabled}"
        --set "components.tls=${tls_enabled}"
    )
    local status=0

    echo "[DEPLOY] Helm ${phase_name}: release=iskaar, components=${database_enabled}/${backend_enabled}/${frontend_enabled}/${tls_enabled}."
    RELEASE_MUTATION_STARTED=true
    if "$HELM" "${helm_args[@]}"; then
        return 0
    else
        status=$?
    fi

    echo "Error: Helm ${phase_name} mutation failed (exit code ${status})." >&2
    print_core_diagnostics "deployment"
    return "$status"
}

deploy_namespace_phase() {
    helm_upgrade_phase "Namespace" false false false false
}

deploy_postgresql_phase() {
    helm_upgrade_phase "PostgreSQL" true false false false
}

deploy_backend_phase() {
    helm_upgrade_phase "Backend" true true false false
}

deploy_frontend_phase() {
    helm_upgrade_phase "Frontend" true true true false
}

deploy_tls_phase() {
    helm_upgrade_phase "TLS/Ingress" true true true true
}

wait_for_postgresql_gate() {
    run_kubernetes_gate "PostgreSQL Service creation" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=create service/postgresql \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "service/postgresql"
        return 1
    }
    run_kubernetes_gate "PostgreSQL rollout/readiness" \
        --namespace "$DEPLOY_NAMESPACE" rollout status deployment/postgresql \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/postgresql"
        return 1
    }
    run_kubernetes_gate "PostgreSQL Ready pod" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=condition=ready pod \
        -l app.kubernetes.io/name=postgresql --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/postgresql"
        return 1
    }
}

wait_for_service_proxy() {
    local gate_name="$1"
    local service_name="$2"
    local service_port="$3"
    local endpoint_path="$4"
    local proxy_path="/api/v1/namespaces/${DEPLOY_NAMESPACE}/services/http:${service_name}:${service_port}/proxy${endpoint_path}"
    local started_at
    local now

    started_at="$(date +%s)"
    while true; do
        if "$KUBECTL" --context "$MINIKUBE_CONTEXT" get --raw="$proxy_path" \
            --request-timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1; then
            echo "[DEPLOY] Gate passed: ${gate_name}."
            return 0
        fi
        now="$(date +%s)"
        if (( now - started_at >= ROLLOUT_TIMEOUT )); then
            echo "Error: ${gate_name} endpoint did not respond within ${ROLLOUT_TIMEOUT}s." >&2
            return 1
        fi
        sleep 1
    done
}

wait_for_backend_gate() {
    run_kubernetes_gate "Backend rollout/readiness" \
        --namespace "$DEPLOY_NAMESPACE" rollout status deployment/iskaar-backend \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/iskaar-backend"
        return 1
    }
    run_kubernetes_gate "Backend Available condition" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=condition=available deployment/iskaar-backend \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/iskaar-backend"
        return 1
    }
    wait_for_service_proxy "Backend health (/actuator/health)" \
        iskaar-backend 8080 /actuator/health || {
        print_core_diagnostics "service/iskaar-backend"
        return 1
    }
}

wait_for_frontend_gate() {
    run_kubernetes_gate "Frontend rollout/readiness" \
        --namespace "$DEPLOY_NAMESPACE" rollout status deployment/iskaar-frontend \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/iskaar-frontend"
        return 1
    }
    run_kubernetes_gate "Frontend Available condition" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=condition=available deployment/iskaar-frontend \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        print_core_diagnostics "deployment/iskaar-frontend"
        return 1
    }
    wait_for_service_proxy "Frontend HTTP readiness (/)" \
        iskaar-frontend 80 / || {
        print_core_diagnostics "service/iskaar-frontend"
        return 1
    }
}

wait_for_tls_gate() {
    run_kubernetes_gate "TLS Certificate readiness" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=condition=Ready \
        certificate/iskaar-games-tls --timeout="${CERTIFICATE_TIMEOUT}s" || {
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' describe certificate/iskaar-games-tls" >&2
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' get events --sort-by=.lastTimestamp" >&2
        return 1
    }
    run_kubernetes_gate "TLS Secret creation" \
        --namespace "$DEPLOY_NAMESPACE" wait --for=create secret/iskaar-games-tls \
        --timeout="${CERTIFICATE_TIMEOUT}s" || {
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' describe certificate/iskaar-games-tls" >&2
        return 1
    }
    echo "[DEPLOY] Gate: TLS Secret data."
    if "$KUBECTL" --context "$MINIKUBE_CONTEXT" --namespace "$DEPLOY_NAMESPACE" \
        get secret/iskaar-games-tls -o 'jsonpath={.data.tls\.crt}' >/dev/null 2>&1; then
        echo "[DEPLOY] Gate passed: TLS Secret data."
    else
        echo "Error: TLS Secret data gate failed." >&2
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n '${DEPLOY_NAMESPACE}' get secret/iskaar-games-tls" >&2
        return 1
    fi
    run_kubernetes_gate "Ingress resource" \
        --namespace "$DEPLOY_NAMESPACE" get ingress/iskaar-ingress -o name || {
        print_core_diagnostics "ingress/iskaar-ingress"
        return 1
    }
}

deploy_monitoring_phase() {
    if [[ "$MONITORING" != true ]]; then
        echo "[DEPLOY] Monitoring phase skipped (monitoring=false)."
        return 0
    fi
    if [[ ! -d "$MONITORING_PATH" ]]; then
        echo "Error: Monitoring manifest directory not found at '${MONITORING_PATH}'." >&2
        return 1
    fi

    local crd
    local -a operator_crds=(
        servicemonitors.monitoring.coreos.com
        prometheusrules.monitoring.coreos.com
        prometheuses.monitoring.coreos.com
        alertmanagers.monitoring.coreos.com
    )
    for crd in "${operator_crds[@]}"; do
        run_kubernetes_gate "Monitoring Operator CRD ${crd}" get crd "$crd" -o name || {
            echo "Error: Monitoring Operator CRD '${crd}' is not available; monitoring manifests were not applied." >&2
            return 1
        }
    done

    echo "[DEPLOY] Monitoring phase: applying manifests from ${MONITORING_PATH}."
    if ! "$KUBECTL" --context "$MINIKUBE_CONTEXT" apply -f "$MONITORING_PATH"; then
        echo "Error: Monitoring manifest application failed." >&2
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n monitoring get pods -o wide" >&2
        return 1
    fi

    local deployment_name
    for deployment_name in alertmanager grafana; do
        run_kubernetes_gate "Monitoring rollout ${deployment_name}" \
            --namespace monitoring rollout status "deployment/${deployment_name}" \
            --timeout="${ROLLOUT_TIMEOUT}s" || {
            echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n monitoring get pods -o wide" >&2
            return 1
        }
    done

    run_kubernetes_gate "Monitoring Prometheus rollout" \
        --namespace monitoring rollout status statefulset/prometheus-iskaar-prometheus \
        --timeout="${ROLLOUT_TIMEOUT}s" || {
        echo "Diagnostics: kubectl --context '${MINIKUBE_CONTEXT}' -n monitoring get prometheus,pods -o wide" >&2
        return 1
    }
    echo "[DEPLOY] Monitoring rollouts completed."
}

# Task 7.4: Show deployment status
show_status() {
    echo "=== Deployment Status ==="

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] kubectl --context ${MINIKUBE_CONTEXT} get pods -n ${NAMESPACE} -o wide"
        echo "[DRY-RUN] kubectl --context ${MINIKUBE_CONTEXT} get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.status.phase}{\"\t\"}{.spec.containers[*].image}{\"\n\"}{end}'"
        return 0
    fi

    "$KUBECTL" --context "$MINIKUBE_CONTEXT" get pods -n "${NAMESPACE}" -o wide
    echo ""
    echo "Pod details:"
    "$KUBECTL" --context "$MINIKUBE_CONTEXT" get pods -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
}

# Post-deployment smoke tests. The smoke script performs the three HTTP checks:
# backend health, frontend index and the WebSocket endpoint.
run_smoke_tests() {
    if [[ "$SKIP_SMOKE" == true ]]; then
        echo "Smoke tests skipped (--skip-smoke)."
        return 0
    fi

    if [[ -z "$SMOKE_BACKEND_URL" || -z "$SMOKE_FRONTEND_URL" ]]; then
        echo "Error: Smoke-test access URLs are unavailable; the local access phase did not complete." >&2
        return 1
    fi

    echo ""
    echo "Running post-deployment smoke tests (timeout=${SMOKE_TIMEOUT}s)..."
    local status=0
    if (
        export TIMEOUT="$SMOKE_TIMEOUT"
        export SMOKE_TIMEOUT="$SMOKE_TIMEOUT"
        # Stream-normalize CRLF so the existing smoke script runs in Bash/WSL
        # without rewriting a tracked file or exposing any deployment values.
        tr -d '\r' < "${SCRIPT_DIR}/smoke-test.sh" | \
            "$BASH_BIN" -s -- "${ENVIRONMENT}" \
            --backend-url "$SMOKE_BACKEND_URL" \
            --frontend-url "$SMOKE_FRONTEND_URL"
    ); then
        status=0
    else
        status=$?
    fi

    if (( status != 0 )); then
        echo "Error: Smoke tests failed (exit code ${status})." >&2
        print_core_diagnostics "deployment"
        return "$status"
    fi

    echo "Smoke tests passed: backend health, frontend index and /ws."
    return 0
}

# Roll back only the release and namespace that were validated for this run.
# No PVC, Secret, or data-volume cleanup is part of the automatic error path.
rollback() {
    local reason="${1:-Unknown reason}"
    local rollback_status=0
    local smoke_status=0

    echo ""
    echo "=== ROLLBACK ==="
    echo "Reason: ${reason}"

    if [[ "$DEPLOY" != true ]]; then
        echo "Error: Rollback is available only in deploy=true mode." >&2
        return 1
    fi

    if [[ "$HAS_PREVIOUS_HELM_REVISION" != true ]]; then
        report_partial_release_state
        return 0
    fi

    if [[ ! "${PREVIOUS_HELM_REVISION}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Refusing rollback because the detected Helm revision is invalid." >&2
        report_partial_release_state
        return 1
    fi

    ROLLBACK_IN_PROGRESS=true
    echo "[DEPLOY] Rolling back release=${HELM_RELEASE_NAME} to revision=${PREVIOUS_HELM_REVISION} in namespace=${DEPLOY_NAMESPACE}."
    if "$HELM" rollback "$HELM_RELEASE_NAME" "$PREVIOUS_HELM_REVISION" \
        --namespace "$DEPLOY_NAMESPACE" \
        --wait \
        "--timeout=${ROLLOUT_TIMEOUT}s"; then
        echo "[DEPLOY] Helm rollback completed with --wait."
    else
        rollback_status=$?
        ROLLBACK_IN_PROGRESS=false
        echo "Error: Helm rollback failed for release=${HELM_RELEASE_NAME} in namespace=${DEPLOY_NAMESPACE} (exit code ${rollback_status})." >&2
        print_core_diagnostics "deployment"
        return "$rollback_status"
    fi

    # --skip-smoke applies to the normal post-deployment smoke phase. When
    # enabled, report that rollback verification is limited to Helm --wait.
    if [[ "$SKIP_SMOKE" == true ]]; then
        echo "[DEPLOY] Rollback smoke test skipped (--skip-smoke); Helm rollback was wait-verified."
        ROLLBACK_IN_PROGRESS=false
        return 0
    fi

    echo "[DEPLOY] Verifying the rolled-back release with the smoke test."
    if run_smoke_tests; then
        echo "[DEPLOY] Rollback smoke-test verification passed."
        ROLLBACK_IN_PROGRESS=false
        return 0
    else
        smoke_status=$?
    fi

    ROLLBACK_IN_PROGRESS=false
    echo "Error: Rollback smoke-test verification failed (exit code ${smoke_status})." >&2
    print_core_diagnostics "deployment"
    return "$smoke_status"
}

handle_deployment_failure() {
    local reason="${1:-deployment failure}"

    if [[ "$DEPLOY" != true || "$RELEASE_MUTATION_STARTED" != true || "$ROLLBACK_IN_PROGRESS" == true ]]; then
        return 0
    fi
    if [[ "$ROLLBACK_ATTEMPTED" == true ]]; then
        echo "[DEPLOY] Automatic rollback was already attempted; no additional release mutation is performed." >&2
        return 0
    fi

    ROLLBACK_ATTEMPTED=true
    if ! rollback "$reason"; then
        echo "Error: Automatic rollback failed or could not be verified; manual intervention is required." >&2
    fi
    return 0
}

# --- Argument Parsing --------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Error: Environment argument is required." >&2
        usage
        exit 1
    fi

    # Check for help flag first
    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    # First positional argument is the environment
    ENVIRONMENT="$1"
    shift

    # Validate environment
    case "$ENVIRONMENT" in
        dev|stage|prod)
            ;;
        *)
            echo "Error: Invalid environment '$ENVIRONMENT'. Must be one of: dev, stage, prod" >&2
            usage
            exit 1
            ;;
    esac

    # Parse remaining options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deploy)
                require_boolean_option_value "--deploy" "${2:-}"
                validate_boolean_option "--deploy" "$2"
                DEPLOY="$2"
                shift 2
                ;;
            --monitoring)
                require_boolean_option_value "--monitoring" "${2:-}"
                validate_boolean_option "--monitoring" "$2"
                MONITORING="$2"
                shift 2
                ;;
            --tag)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --tag requires a value." >&2
                    usage
                    exit 1
                fi
                TAG_OVERRIDE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-smoke)
                SKIP_SMOKE=true
                shift
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [[ "$DEPLOY" == true && "$ENVIRONMENT" != "dev" ]]; then
        echo "Error: --deploy true is allowed only with environment 'dev'; Minikube mode uses the local dev target." >&2
        exit 1
    fi

    if [[ "$DRY_RUN" == true && "$DEPLOY" == true ]]; then
        echo "Error: --dry-run cannot be combined with --deploy true." >&2
        exit 1
    fi
}

# --- Main Orchestration ------------------------------------------------------

main() {
    parse_args "$@"

    echo "=== Iskaar Deploy ==="
    print_mode_summary
    echo "Dry-run: $DRY_RUN"
    echo ""

    if [[ "$DEPLOY" == false ]]; then
        local readiness_status=0
        run_readiness_validation || readiness_status=$?
        if (( readiness_status != 0 )); then
            exit "$readiness_status"
        fi
        exit 0
    fi

    validate_prerequisites
    # The guard and local-secret preflight must run before the setup helper and
    # before any Namespace, Secret, or Helm mutation can be reached.
    validate_deploy_safety_configuration
    load_local_postgres_credentials
    run_minikube_setup
    ensure_minikube_running
    determine_tag
    check_registry
    build_images
    push_images
    # Capture the currently deployed revision before the first Helm release
    # mutation. A history inspection failure aborts without changing resources.
    detect_previous_helm_revision

    # Core mutations are deliberately linear. A later component is not
    # rendered until the preceding Helm mutation and readiness gate succeeded.
    run_deploy_phase "Namespace" ensure_deploy_namespace
    run_deploy_phase "Namespace Helm" deploy_namespace_phase
    run_deploy_phase "Local Secret" create_local_postgres_secret

    run_deploy_phase "PostgreSQL" deploy_postgresql_phase
    run_deploy_phase "PostgreSQL readiness" wait_for_postgresql_gate

    run_deploy_phase "Backend" deploy_backend_phase
    run_deploy_phase "Backend readiness" wait_for_backend_gate

    run_deploy_phase "Frontend" deploy_frontend_phase
    run_deploy_phase "Frontend readiness" wait_for_frontend_gate

    run_deploy_phase "TLS/Ingress" deploy_tls_phase
    run_deploy_phase "TLS/Ingress readiness" wait_for_tls_gate

    # Monitoring is intentionally after the complete Core_Stack. A false value
    # is reported as skipped and never touches the monitoring manifest tree.
    run_deploy_phase "Monitoring" deploy_monitoring_phase
    run_deploy_phase "Deployment status" show_status

    local smoke_status=0
    if run_deploy_phase "Smoke tests" run_smoke_tests; then
        smoke_status=0
    else
        smoke_status=$?
    fi
    if (( smoke_status != 0 )); then
        echo ""
        echo "=== Deployment FAILED (smoke test or access gate) ===" >&2
        exit "$smoke_status"
    fi

    echo ""
    echo "=== Deployment complete ==="
}

# --- Entry Point -------------------------------------------------------------
# NOTE: Make this script executable with: chmod +x deploy.sh

main "$@"
