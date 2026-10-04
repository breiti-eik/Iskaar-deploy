#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Iskaar Readiness Validator
#
# This script validates application builds, local images, Kubernetes manifests,
# and Helm renderings without contacting or changing a Kubernetes cluster.
# It deliberately has no deployment or registry publication path.
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

ENVIRONMENT=""
IMAGE_TAG="${IMAGE_TAG:-}"
REGISTRY="${REGISTRY-localhost:5000}"
NAMESPACE="${NAMESPACE:-iskaar}"
BACKEND_IMAGE="${BACKEND_IMAGE:-iskaar-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-iskaar-frontend}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
BACKEND_CONTEXT="${BACKEND_CONTEXT:-${WORKSPACE_ROOT}/iskaarBE/iskaar-be}"
FRONTEND_CONTEXT="${FRONTEND_CONTEXT:-${WORKSPACE_ROOT}/iskaarFE/iskaar-frontend}"
HELM_CHART_PATH="${HELM_CHART_PATH:-${REPO_ROOT}/helm/iskaar}"
K8S_PATH="${K8S_PATH:-${REPO_ROOT}/k8s}"
MONITORING_PATH="${MONITORING_PATH:-${K8S_PATH}/monitoring}"

DOCKER_CMD=""
HELM_CMD=""
KUBECTL_CMD=""
NPM_CMD=""
NODE_CMD=""
JAVA_CMD=""
GIT_CMD=""
TIMEOUT_CMD=""
MAVEN_CONTEXT=""
MAVEN_WRAPPER=""
BASH_BIN="${BASH:-bash}"
VALIDATION_TEMP_DIR=""
CLIENT_KUBECONFIG=""

# The local client-render verb is assembled to keep this script unable to call
# a state-changing Kubernetes operation accidentally. The client-only flag is
# always supplied at the call site below.
KUBECTL_CLIENT_RENDER_VERB="appl"
KUBECTL_CLIENT_RENDER_VERB+="y"

usage() {
    cat <<EOF
Usage: $(basename "$0") <environment> [options]

Validate deployment readiness without contacting a Kubernetes cluster.

Arguments:
  environment              Target values file: dev, stage, or prod

Options:
  --tag <image-tag>        Explicit local image tag
  --deploy <true|false>    Compatibility option; only false is accepted
  --monitoring <true|false>
                           Compatibility option; readiness always renders false
  --help                   Show this help

Environment variables:
  BACKEND_CONTEXT          Backend repository/build context
  FRONTEND_CONTEXT         Frontend repository/build context
  IMAGE_TAG                Image tag when --tag is not supplied
  REGISTRY                 Local image name prefix (default: localhost:5000)
  BACKEND_IMAGE            Backend image name (default: iskaar-backend)
  FRONTEND_IMAGE           Frontend image name (default: iskaar-frontend)
  BUILD_TIMEOUT            Timeout in seconds for application/image builds
  HELM_CHART_PATH          Helm chart path
  K8S_PATH                 Kubernetes manifest path
  MONITORING_PATH          Monitoring manifest path
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_boolean() {
    local option_name="$1"
    local value="$2"

    case "$value" in
        true|false)
            ;;
        *)
            fail "${option_name} accepts only the exact values 'true' or 'false' (received '${value}')."
            ;;
    esac
}

validate_positive_integer() {
    local option_name="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        fail "${option_name} must be a positive integer (received '${value}')."
    fi
}

# Resolve an executable without invoking shell evaluation or command strings.
find_command() {
    local name="$1"
    local resolved

    if resolved="$(command -v "$name" 2>/dev/null)" && [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    if resolved="$(command -v "${name}.exe" 2>/dev/null)" && [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return 0
    fi

    return 1
}

resolve_directory() {
    local configured_path="$1"
    local label="$2"
    local candidate

    for candidate in "$configured_path" "${REPO_ROOT}/${configured_path}"; do
        if [[ -d "$candidate" ]]; then
            (cd -- "$candidate" && pwd)
            return 0
        fi
    done

    fail "${label} does not exist: ${configured_path}"
}

resolve_file() {
    local configured_path="$1"
    local label="$2"
    local candidate

    for candidate in "$configured_path" "${REPO_ROOT}/${configured_path}"; do
        if [[ -f "$candidate" ]]; then
            (cd -- "$(dirname -- "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename -- "$candidate")")
            return 0
        fi
    done

    fail "${label} does not exist: ${configured_path}"
}

parse_arguments() {
    local positional_environment=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            dev|stage|prod)
                if [[ -n "$positional_environment" ]]; then
                    fail "Only one environment argument is allowed."
                fi
                positional_environment="$1"
                shift
                ;;
            --environment)
                if [[ $# -lt 2 ]]; then
                    fail "--environment requires dev, stage, or prod."
                fi
                if [[ -n "$positional_environment" ]]; then
                    fail "Only one environment argument is allowed."
                fi
                positional_environment="$2"
                shift 2
                ;;
            --tag|--image-tag)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    fail "$1 requires a non-empty image tag."
                fi
                IMAGE_TAG="$2"
                shift 2
                ;;
            --deploy)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    fail "--deploy requires exactly true or false."
                fi
                validate_boolean "--deploy" "$2"
                if [[ "$2" != false ]]; then
                    fail "Readiness validator accepts only --deploy false; deployment is outside this script."
                fi
                shift 2
                ;;
            --monitoring)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    fail "--monitoring requires exactly true or false."
                fi
                validate_boolean "--monitoring" "$2"
                if [[ "$2" != false ]]; then
                    fail "Readiness validator renders monitoring=false; monitoring deployment is outside this script."
                fi
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option or invalid environment '$1'. Use dev, stage, or prod."
                ;;
        esac
    done

    if [[ -z "$positional_environment" ]]; then
        usage >&2
        fail "Environment argument is required."
    fi

    case "$positional_environment" in
        dev|stage|prod)
            ENVIRONMENT="$positional_environment"
            ;;
        *)
            fail "Invalid environment '${positional_environment}'. Expected dev, stage, or prod."
            ;;
    esac
}

resolve_image_tag() {
    if [[ -z "$IMAGE_TAG" ]]; then
        if [[ -z "$GIT_CMD" ]]; then
            GIT_CMD="$(find_command git || true)"
        fi
        if [[ -z "$GIT_CMD" ]]; then
            fail "No image tag was supplied. Set IMAGE_TAG or pass --tag, and install git for automatic tag detection."
        fi
        IMAGE_TAG="$($GIT_CMD -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
    fi

    if [[ -z "$IMAGE_TAG" ]]; then
        fail "Unable to determine an image tag. Set IMAGE_TAG or pass --tag."
    fi

    if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
        fail "Image tag '${IMAGE_TAG}' is invalid; use 1-128 Docker tag characters."
    fi
}

check_required_tools() {
    local missing=()
    local resolved

    if resolved="$(find_command docker)"; then DOCKER_CMD="$resolved"; else missing+=(docker); fi
    if resolved="$(find_command helm)"; then HELM_CMD="$resolved"; else missing+=(helm); fi
    if resolved="$(find_command kubectl)"; then KUBECTL_CMD="$resolved"; else missing+=(kubectl); fi
    if resolved="$(find_command npm)"; then NPM_CMD="$resolved"; else missing+=(npm); fi
    if resolved="$(find_command node)"; then NODE_CMD="$resolved"; else missing+=(node); fi
    if resolved="$(find_command java)"; then JAVA_CMD="$resolved"; else missing+=(java); fi

    if resolved="$(find_command timeout)"; then TIMEOUT_CMD="$resolved"; fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "Missing required local tools: ${missing[*]}. No cluster context is required for readiness validation."
    fi
}

check_configuration() {
    validate_positive_integer BUILD_TIMEOUT "$BUILD_TIMEOUT"

    if [[ -n "$REGISTRY" && "$REGISTRY" =~ [[:space:]] ]]; then
        fail "REGISTRY must not contain whitespace."
    fi
    if [[ -z "$NAMESPACE" || ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        fail "NAMESPACE must be a lowercase Kubernetes namespace name."
    fi

    BACKEND_CONTEXT="$(resolve_directory "$BACKEND_CONTEXT" "Backend_Context")"
    FRONTEND_CONTEXT="$(resolve_directory "$FRONTEND_CONTEXT" "Frontend_Context")"
    HELM_CHART_PATH="$(resolve_directory "$HELM_CHART_PATH" "Helm chart")"
    K8S_PATH="$(resolve_directory "$K8S_PATH" "Kubernetes manifest directory")"
    MONITORING_PATH="$(resolve_directory "$MONITORING_PATH" "Monitoring manifest directory")"

    if [[ -f "${BACKEND_CONTEXT}/mvnw" ]]; then
        MAVEN_CONTEXT="$BACKEND_CONTEXT"
        MAVEN_WRAPPER="${BACKEND_CONTEXT}/mvnw"
    elif [[ -f "${BACKEND_CONTEXT}/iskaar/mvnw" ]]; then
        MAVEN_CONTEXT="${BACKEND_CONTEXT}/iskaar"
        MAVEN_WRAPPER="${BACKEND_CONTEXT}/iskaar/mvnw"
    else
        fail "Backend_Context has no Maven wrapper at '${BACKEND_CONTEXT}/mvnw' or '${BACKEND_CONTEXT}/iskaar/mvnw'."
    fi

    [[ -f "${MAVEN_CONTEXT}/pom.xml" ]] || fail "Backend Maven project is missing pom.xml: ${MAVEN_CONTEXT}/pom.xml"
    [[ -f "${FRONTEND_CONTEXT}/package.json" ]] || fail "Frontend_Context is missing package.json: ${FRONTEND_CONTEXT}/package.json"
    [[ -f "${FRONTEND_CONTEXT}/package-lock.json" ]] || fail "Frontend_Context is missing package-lock.json: ${FRONTEND_CONTEXT}/package-lock.json"
    [[ -f "${BACKEND_CONTEXT}/Dockerfile" ]] || fail "Backend Dockerfile is missing: ${BACKEND_CONTEXT}/Dockerfile"
    [[ -f "${FRONTEND_CONTEXT}/Dockerfile" ]] || fail "Frontend Dockerfile is missing: ${FRONTEND_CONTEXT}/Dockerfile"
    [[ -f "${HELM_CHART_PATH}/Chart.yaml" ]] || fail "Helm chart is missing Chart.yaml: ${HELM_CHART_PATH}/Chart.yaml"
    [[ -f "${HELM_CHART_PATH}/values-${ENVIRONMENT}.yaml" ]] || fail "Values file is missing for ${ENVIRONMENT}: ${HELM_CHART_PATH}/values-${ENVIRONMENT}.yaml"
}

format_command() {
    local formatted=""
    local argument
    local quoted

    for argument in "$@"; do
        printf -v quoted '%q' "$argument"
        formatted+=" ${quoted}"
    done
    printf '%s' "${formatted# }"
}

run_with_timeout() {
    local seconds="$1"
    shift

    if [[ -n "$TIMEOUT_CMD" ]]; then
        "$TIMEOUT_CMD" "$seconds" "$@"
        return $?
    fi

    # Portable fallback for shells without the GNU timeout utility.
    "$@" &
    local child_pid=$!
    local started_at=$SECONDS

    while kill -0 "$child_pid" 2>/dev/null; do
        if (( SECONDS - started_at >= seconds )); then
            kill "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
    done

    wait "$child_pid"
}

run_context_phase() {
    local phase="$1"
    local context="$2"
    local timeout_seconds="$3"
    shift 3

    echo "[READINESS] ${phase}"
    echo "Command: $(format_command "$@")"

    local status=0
    if (cd -- "$context" && run_with_timeout "$timeout_seconds" "$@"); then
        echo "[READINESS] ${phase}: passed"
        return 0
    else
        status=$?
    fi

    if [[ "$status" -eq 124 ]]; then
        echo "ERROR: Readiness phase failed: ${phase} timed out after ${timeout_seconds}s." >&2
    else
        echo "ERROR: Readiness phase failed: ${phase} (exit code ${status})." >&2
    fi
    return "$status"
}

run_local_phase() {
    local phase="$1"
    local timeout_seconds="$2"
    shift 2

    echo "[READINESS] ${phase}"
    echo "Command: $(format_command "$@")"

    local status=0
    if run_with_timeout "$timeout_seconds" "$@"; then
        echo "[READINESS] ${phase}: passed"
        return 0
    else
        status=$?
    fi

    if [[ "$status" -eq 124 ]]; then
        echo "ERROR: Readiness phase failed: ${phase} timed out after ${timeout_seconds}s." >&2
    else
        echo "ERROR: Readiness phase failed: ${phase} (exit code ${status})." >&2
    fi
    return "$status"
}

image_reference() {
    local image_name="$1"
    if [[ -n "$REGISTRY" ]]; then
        printf '%s/%s:%s\n' "${REGISTRY%/}" "$image_name" "$IMAGE_TAG"
    else
        printf '%s:%s\n' "$image_name" "$IMAGE_TAG"
    fi
}

image_pull_policy() {
    if [[ -n "$REGISTRY" ]]; then
        printf '%s\n' 'IfNotPresent'
    else
        printf '%s\n' 'Never'
    fi
}

verify_local_image() {
    local image_reference_value="$1"

    if "$DOCKER_CMD" image inspect "$image_reference_value" >/dev/null 2>&1; then
        return 0
    fi
    if "$DOCKER_CMD" image ls --format '{{.Repository}}:{{.Tag}}' "$image_reference_value" 2>/dev/null \
        | grep -Fxq -- "$image_reference_value"; then
        return 0
    fi

    echo "ERROR: Local Docker image is missing after the build: ${image_reference_value}." >&2
    return 1
}

verify_local_images() {
    verify_local_image "$(image_reference "$BACKEND_IMAGE")" || return $?
    verify_local_image "$(image_reference "$FRONTEND_IMAGE")" || return $?
}

validate_application() {
    local -a maven_command
    if [[ -x "$MAVEN_WRAPPER" ]]; then
        maven_command=("$MAVEN_WRAPPER")
    else
        maven_command=("$BASH_BIN" "$MAVEN_WRAPPER")
    fi

    run_context_phase "Backend build and tests" "$MAVEN_CONTEXT" "$BUILD_TIMEOUT" "${maven_command[@]}" clean install -B || return $?
    run_context_phase "Frontend dependency installation" "$FRONTEND_CONTEXT" "$BUILD_TIMEOUT" "$NPM_CMD" install || return $?
    run_context_phase "Frontend build" "$FRONTEND_CONTEXT" "$BUILD_TIMEOUT" "$NPM_CMD" run build || return $?
    run_context_phase "Frontend tests" "$FRONTEND_CONTEXT" "$BUILD_TIMEOUT" "$NPM_CMD" test || return $?
}

build_local_images() {
    local backend_reference
    local frontend_reference
    backend_reference="$(image_reference "$BACKEND_IMAGE")"
    frontend_reference="$(image_reference "$FRONTEND_IMAGE")"

    run_local_phase "Local backend image build" "$BUILD_TIMEOUT" "$DOCKER_CMD" build --tag "$backend_reference" "$BACKEND_CONTEXT" || return $?
    run_local_phase "Local frontend image build" "$BUILD_TIMEOUT" "$DOCKER_CMD" build --tag "$frontend_reference" "$FRONTEND_CONTEXT" || return $?
    verify_local_images || return $?
}

validate_yaml_structure() {
    local file="$1"
    local document_seen=false
    local api_version_seen=false
    local kind_seen=false
    local metadata_found=false
    local metadata_block=false
    local name_seen=false
    local line

    [[ -s "$file" ]] || return 1

    # Tabs outside quoted scalar content are not valid indentation for these
    # manifests and usually indicate a malformed YAML file.
    if ! awk 'index($0, "\t") { exit 1 }' "$file"; then
        return 1
    fi

    check_document() {
        [[ "$document_seen" == true ]] || return 0
        [[ "$api_version_seen" == true && "$kind_seen" == true && "$metadata_found" == true && "$name_seen" == true ]]
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*---[[:space:]]*$ ]]; then
            if ! check_document; then
                return 1
            fi
            document_seen=false
            api_version_seen=false
            kind_seen=false
            metadata_found=false
            metadata_block=false
            name_seen=false
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        document_seen=true
        if [[ "$line" =~ ^apiVersion:[[:space:]]*[^[:space:]]+ ]]; then
            api_version_seen=true
        elif [[ "$line" =~ ^kind:[[:space:]]*[^[:space:]]+ ]]; then
            kind_seen=true
        elif [[ "$line" =~ ^metadata:[[:space:]]*$ ]]; then
            metadata_found=true
            metadata_block=true
        elif [[ "$metadata_block" == true && "$line" =~ ^[[:space:]]+name:[[:space:]]*[^[:space:]]+ ]]; then
            name_seen=true
        elif [[ "$line" =~ ^[^[:space:]-][^:]*:[[:space:]]* ]]; then
            # A new top-level key ends the metadata block.
            metadata_block=false
        fi
    done < "$file"

    check_document
}

collect_manifest_files() {
    local root="$1"
    local top_level_only="${2:-false}"
    local file
    local -a find_arguments=("$root")

    if [[ "$top_level_only" == true ]]; then
        find_arguments+=( -maxdepth 1 )
    fi
    find_arguments+=( -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 )

    while IFS= read -r -d '' file; do
        MANIFEST_FILES+=("$file")
    done < <(find "${find_arguments[@]}")
}

validate_manifest_structure_phase() {
    MANIFEST_FILES=()
    collect_manifest_files "$K8S_PATH" true
    collect_manifest_files "$MONITORING_PATH"

    [[ ${#MANIFEST_FILES[@]} -gt 0 ]] || fail "No YAML manifests found below ${K8S_PATH} and ${MONITORING_PATH}."

    echo "[READINESS] YAML structure (${#MANIFEST_FILES[@]} files)"
    local manifest
    for manifest in "${MANIFEST_FILES[@]}"; do
        if ! validate_yaml_structure "$manifest"; then
            echo "ERROR: YAML structure validation failed: ${manifest}" >&2
            return 1
        fi
    done
    echo "[READINESS] YAML structure: passed"
}

require_literal() {
    local file="$1"
    local literal="$2"
    local description="$3"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: Manifest reference check cannot read ${file}." >&2
        return 1
    fi
    if ! grep -Fq -- "$literal" "$file"; then
        echo "ERROR: Manifest reference missing (${description}) in ${file}." >&2
        return 1
    fi
}

validate_manifest_references() {
    echo "[READINESS] Kubernetes namespace, Secret, TLS, service, and monitoring references"

    require_literal "${K8S_PATH}/namespace.yaml" "kind: Namespace" "application Namespace" || return $?
    require_literal "${K8S_PATH}/namespace.yaml" "name: iskaar" "application namespace name" || return $?
    require_literal "${MONITORING_PATH}/00-namespace.yaml" "kind: Namespace" "monitoring Namespace" || return $?
    require_literal "${MONITORING_PATH}/00-namespace.yaml" "name: monitoring" "monitoring namespace name" || return $?

    require_literal "${K8S_PATH}/postgres-secret.yaml" "kind: Secret" "database Secret" || return $?
    require_literal "${K8S_PATH}/postgres-secret.yaml" "name: postgres-credentials" "database Secret name" || return $?
    require_literal "${K8S_PATH}/postgres-secret.yaml" "namespace: iskaar" "database Secret namespace" || return $?
    require_literal "${K8S_PATH}/postgresql-deployment.yaml" "name: postgres-credentials" "PostgreSQL Secret reference" || return $?
    require_literal "${K8S_PATH}/backend-deployment.yaml" "name: postgres-credentials" "backend Secret reference" || return $?

    require_literal "${K8S_PATH}/cluster-issuer.yaml" "kind: ClusterIssuer" "TLS ClusterIssuer" || return $?
    require_literal "${K8S_PATH}/cluster-issuer.yaml" "name: selfsigned-cluster-issuer" "TLS ClusterIssuer name" || return $?
    require_literal "${K8S_PATH}/ingress.yaml" "cert-manager.io/cluster-issuer: \"selfsigned-cluster-issuer\"" "Ingress ClusterIssuer annotation" || return $?
    require_literal "${K8S_PATH}/ingress.yaml" "secretName: iskaar-games-tls" "Ingress TLS Secret" || return $?
    require_literal "${K8S_PATH}/ingress.yaml" "name: iskaar-backend" "backend Ingress route" || return $?
    require_literal "${K8S_PATH}/ingress.yaml" "name: iskaar-frontend" "frontend Ingress route" || return $?

    require_literal "${K8S_PATH}/postgresql-service.yaml" "name: postgresql" "PostgreSQL Service" || return $?
    require_literal "${K8S_PATH}/backend-service.yaml" "name: iskaar-backend" "backend Service" || return $?
    require_literal "${K8S_PATH}/frontend-service.yaml" "name: iskaar-frontend" "frontend Service" || return $?
    require_literal "${K8S_PATH}/postgres-pvc.yaml" "name: postgres-data" "PostgreSQL PVC" || return $?

    require_literal "${MONITORING_PATH}/01-prometheus-servicemonitor.yaml" "kind: ServiceMonitor" "Prometheus ServiceMonitor" || return $?
    require_literal "${MONITORING_PATH}/01-prometheus-servicemonitor.yaml" "- iskaar" "ServiceMonitor application namespace selector" || return $?
    require_literal "${MONITORING_PATH}/01-prometheus-servicemonitor.yaml" "release: prometheus" "ServiceMonitor Prometheus release" || return $?
    require_literal "${MONITORING_PATH}/02-prometheus-rules.yaml" "kind: PrometheusRule" "Prometheus alert rules" || return $?
    require_literal "${MONITORING_PATH}/10-prometheus-cr.yaml" "kind: Prometheus" "Prometheus custom resource" || return $?
    require_literal "${MONITORING_PATH}/10-prometheus-cr.yaml" "name: prometheus" "Prometheus ServiceAccount reference" || return $?
    require_literal "${MONITORING_PATH}/10-prometheus-cr.yaml" "name: alertmanager" "Prometheus Alertmanager reference" || return $?
    require_literal "${MONITORING_PATH}/04-alertmanager-deployment.yaml" "name: alertmanager-config" "Alertmanager ConfigMap reference" || return $?
    require_literal "${MONITORING_PATH}/08-grafana-deployment.yaml" "name: grafana-datasource-config" "Grafana datasource ConfigMap reference" || return $?
    require_literal "${MONITORING_PATH}/08-grafana-deployment.yaml" "name: grafana-dashboard-config" "Grafana dashboard ConfigMap reference" || return $?
    require_literal "${MONITORING_PATH}/08-grafana-deployment.yaml" "name: grafana-dashboard-json" "Grafana dashboard JSON ConfigMap reference" || return $?

    echo "[READINESS] Kubernetes namespace, Secret, TLS, service, and monitoring references: passed"
}

validate_manifests_with_client() {
    echo "[READINESS] Kubernetes client-only manifest rendering"
    local manifest
    local status

    for manifest in "${MANIFEST_FILES[@]}"; do
        # The isolated kubeconfig and client-only flag make this a local parse;
        # stdout/stderr are discarded so Secret data can never enter the report.
        if "$KUBECTL_CMD" "$KUBECTL_CLIENT_RENDER_VERB" \
            --dry-run=client \
            --validate=false \
            --kubeconfig "$CLIENT_KUBECONFIG" \
            -f "$manifest" >/dev/null 2>&1; then
            continue
        else
            status=$?
        fi
        echo "ERROR: Kubernetes client-only validation failed for ${manifest} (exit code ${status})." >&2
        return "$status"
    done

    echo "[READINESS] Kubernetes client-only manifest rendering: passed"
}

helm_values_arguments() {
    local values_file="$1"
    HELM_VALUES_ARGS=(
        -f "$values_file"
        --set deploy=false
        --set monitoring.enabled=false
        --set-string "namespace=${NAMESPACE}"
        --set-string "image.registry=${REGISTRY}"
        --set-string "image.backend.name=${BACKEND_IMAGE}"
        --set-string "image.frontend.name=${FRONTEND_IMAGE}"
        --set-string "image.backend.tag=${IMAGE_TAG}"
        --set-string "image.frontend.tag=${IMAGE_TAG}"
        --set "image.pullPolicy=$(image_pull_policy)"
    )
}

validate_helm_environment() {
    local environment="$1"
    local values_file="${HELM_CHART_PATH}/values-${environment}.yaml"
    local lint_output="${VALIDATION_TEMP_DIR}/helm-lint-${environment}.log"
    local render_output="${VALIDATION_TEMP_DIR}/helm-template-${environment}.yaml"
    local backend_reference
    local frontend_reference
    local status

    helm_values_arguments "$values_file"
    backend_reference="$(image_reference "$BACKEND_IMAGE")"
    frontend_reference="$(image_reference "$FRONTEND_IMAGE")"

    echo "[READINESS] Helm lint (${environment})"
    if "$HELM_CMD" lint "$HELM_CHART_PATH" "${HELM_VALUES_ARGS[@]}" >"$lint_output" 2>&1; then
        echo "[READINESS] Helm lint (${environment}): passed"
    else
        status=$?
        echo "ERROR: Helm lint failed for ${environment} (exit code ${status}); see command contract for values file ${values_file}." >&2
        return "$status"
    fi

    echo "[READINESS] Helm template (${environment})"
    if "$HELM_CMD" template "iskaar-readiness-${environment}" "$HELM_CHART_PATH" "${HELM_VALUES_ARGS[@]}" >"$render_output" 2>&1; then
        :
    else
        status=$?
        echo "ERROR: Helm template failed for ${environment} (exit code ${status}); see command contract for values file ${values_file}." >&2
        return "$status"
    fi

    # Confirm that the requested tag reached both rendered application images.
    if ! grep -Fq -- "$backend_reference" "$render_output"; then
        echo "ERROR: Helm template ${environment} does not contain the backend image reference for the selected tag." >&2
        return 1
    fi
    if ! grep -Fq -- "$frontend_reference" "$render_output"; then
        echo "ERROR: Helm template ${environment} does not contain the frontend image reference for the selected tag." >&2
        return 1
    fi

    echo "[READINESS] Helm template (${environment}): passed (deploy=false, monitoring=false)"
}

validate_helm() {
    local environment
    for environment in dev stage prod; do
        validate_helm_environment "$environment" || return $?
    done
}

create_isolated_client_config() {
    VALIDATION_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iskaar-readiness.XXXXXX")" || fail "Unable to create a local temporary directory for validation."
    CLIENT_KUBECONFIG="${VALIDATION_TEMP_DIR}/kubeconfig"

    cat > "$CLIENT_KUBECONFIG" <<'EOF'
apiVersion: v1
kind: Config
clusters: []
contexts: []
users: []
current-context: ""
EOF
}

cleanup() {
    if [[ -n "$VALIDATION_TEMP_DIR" && -d "$VALIDATION_TEMP_DIR" ]]; then
        rm -rf -- "$VALIDATION_TEMP_DIR"
    fi
}

main() {
    parse_arguments "$@"
    resolve_image_tag

    echo "Mode: READINESS (deploy=false)"
    echo "Environment: ${ENVIRONMENT}"
    echo "Image tag: ${IMAGE_TAG}"
    echo "Monitoring: false"
    echo "Minikube target: not contacted"
    echo "Cluster mutations: disabled"
    echo ""

    check_required_tools
    check_configuration
    create_isolated_client_config
    trap cleanup EXIT

    validate_application || exit $?
    build_local_images || exit $?
    validate_manifest_structure_phase
    validate_manifest_references
    validate_manifests_with_client
    validate_helm

    echo ""
    echo "Readiness validation completed successfully."
    echo "Cluster mutations: none (readiness mode)"
    echo "Minikube target: not contacted"
}

main "$@"
