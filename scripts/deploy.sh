#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Iskaar Deploy Script
# Orchestrates: Build → Push → Rollout for the Iskaar project
# Usage: ./deploy.sh <environment> [--tag <image-tag>] [--dry-run]
# =============================================================================

# --- Configuration Variables -------------------------------------------------

REGISTRY="${REGISTRY:-localhost:5000}"
NAMESPACE="${NAMESPACE:-iskaar}"
BACKEND_IMAGE="${BACKEND_IMAGE:-iskaar-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-iskaar-frontend}"
HELM_CHART_PATH="${HELM_CHART_PATH:-helm/iskaar}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120}"
BACKEND_CONTEXT="${BACKEND_CONTEXT:-../iskaarBE/iskaar-be}"
FRONTEND_CONTEXT="${FRONTEND_CONTEXT:-../iskaarFE/iskaar-frontend}"

# --- Runtime State -----------------------------------------------------------

ENVIRONMENT=""
TAG_OVERRIDE=""
DRY_RUN=false
IMAGE_TAG=""
PRIMARY_TAG=""

# --- Helper Functions --------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") <environment> [options]

Deploy the Iskaar application to a Kubernetes cluster.

Arguments:
  environment          Target environment: dev, stage, or prod

Options:
  --tag <image-tag>    Override the image tag (default: determined from git)
  --dry-run            Print commands without executing them
  -h, --help           Show this help message

Examples:
  $(basename "$0") dev
  $(basename "$0") stage --tag v1.0.0
  $(basename "$0") prod --tag v2.1.0 --dry-run

Configuration (environment variables):
  REGISTRY             Container registry address (default: localhost:5000)
  NAMESPACE            Kubernetes namespace (default: iskaar)
  BACKEND_IMAGE        Backend image name (default: iskaar-backend)
  FRONTEND_IMAGE       Frontend image name (default: iskaar-frontend)
  HELM_CHART_PATH      Path to Helm chart (default: helm/iskaar)
  BUILD_TIMEOUT        Max build duration in seconds (default: 300)
  ROLLOUT_TIMEOUT      Max rollout duration in seconds (default: 120)
  BACKEND_CONTEXT      Docker build context for backend (default: ../iskaarBE/iskaar-be)
  FRONTEND_CONTEXT     Docker build context for frontend (default: ../iskaarFE/iskaar-frontend)
EOF
}

validate_prerequisites() {
    local missing=()

    for cmd in git docker helm kubectl; do
        if ! command -v "$cmd" &>/dev/null; then
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

# --- Core Functions (placeholders for tasks 7.2-7.5) -------------------------

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

# Task 7.3: Registry health check
check_registry() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] curl -sf http://localhost:5000/v2/"
        return 0
    fi

    echo "Checking registry at localhost:5000..."
    if ! curl -sf http://localhost:5000/v2/ >/dev/null 2>&1; then
        echo "Error: Minikube registry not running. Run: minikube addons enable registry" >&2
        exit 1
    fi
    echo "Registry is available."
}

# Task 7.3: Build Docker images
build_images() {
    echo "Building backend image..."
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] timeout ${BUILD_TIMEOUT} docker build -t ${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG} ${BACKEND_CONTEXT}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker tag ${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG} ${REGISTRY}/${BACKEND_IMAGE}:${PRIMARY_TAG}"
        fi
        echo "[DRY-RUN] timeout ${BUILD_TIMEOUT} docker build -t ${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG} ${FRONTEND_CONTEXT}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker tag ${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG} ${REGISTRY}/${FRONTEND_IMAGE}:${PRIMARY_TAG}"
        fi
        return 0
    fi

    # Build backend
    if ! timeout "${BUILD_TIMEOUT}" docker build -t "${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG}" "${BACKEND_CONTEXT}"; then
        echo "Error: Backend image build failed." >&2
        exit 1
    fi

    # Tag backend with primary tag if set
    if [[ -n "${PRIMARY_TAG}" ]]; then
        docker tag "${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG}" "${REGISTRY}/${BACKEND_IMAGE}:${PRIMARY_TAG}"
    fi

    echo "Building frontend image..."

    # Build frontend
    if ! timeout "${BUILD_TIMEOUT}" docker build -t "${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG}" "${FRONTEND_CONTEXT}"; then
        echo "Error: Frontend image build failed." >&2
        exit 1
    fi

    # Tag frontend with primary tag if set
    if [[ -n "${PRIMARY_TAG}" ]]; then
        docker tag "${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG}" "${REGISTRY}/${FRONTEND_IMAGE}:${PRIMARY_TAG}"
    fi

    echo "Images built successfully."
}

# Task 7.4: Push images to registry
push_images() {
    echo "Pushing images to registry..."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] docker push ${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG}"
        echo "[DRY-RUN] docker push ${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG}"
        if [[ -n "${PRIMARY_TAG}" ]]; then
            echo "[DRY-RUN] docker push ${REGISTRY}/${BACKEND_IMAGE}:${PRIMARY_TAG}"
            echo "[DRY-RUN] docker push ${REGISTRY}/${FRONTEND_IMAGE}:${PRIMARY_TAG}"
        fi
        return 0
    fi

    # Push backend image
    if ! docker push "${REGISTRY}/${BACKEND_IMAGE}:${IMAGE_TAG}"; then
        echo "Error: Failed to push ${BACKEND_IMAGE}." >&2
        exit 1
    fi

    # Push frontend image
    if ! docker push "${REGISTRY}/${FRONTEND_IMAGE}:${IMAGE_TAG}"; then
        echo "Error: Failed to push ${FRONTEND_IMAGE}." >&2
        exit 1
    fi

    # Push primary tag if set
    if [[ -n "${PRIMARY_TAG}" ]]; then
        if ! docker push "${REGISTRY}/${BACKEND_IMAGE}:${PRIMARY_TAG}"; then
            echo "Error: Failed to push ${BACKEND_IMAGE}." >&2
            exit 1
        fi
        if ! docker push "${REGISTRY}/${FRONTEND_IMAGE}:${PRIMARY_TAG}"; then
            echo "Error: Failed to push ${FRONTEND_IMAGE}." >&2
            exit 1
        fi
    fi

    echo "Images pushed successfully."
}

# Task 7.4: Deploy to cluster via Helm
deploy_to_cluster() {
    echo "Deploying to cluster (environment: ${ENVIRONMENT})..."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] helm upgrade --install iskaar ${HELM_CHART_PATH} -f ${HELM_CHART_PATH}/values-${ENVIRONMENT}.yaml --set image.backend.tag=${IMAGE_TAG} --set image.frontend.tag=${IMAGE_TAG} -n ${NAMESPACE}"
        return 0
    fi

    if ! helm upgrade --install iskaar "${HELM_CHART_PATH}" \
        -f "${HELM_CHART_PATH}/values-${ENVIRONMENT}.yaml" \
        --set "image.backend.tag=${IMAGE_TAG}" \
        --set "image.frontend.tag=${IMAGE_TAG}" \
        -n "${NAMESPACE}"; then
        echo "Error: Helm deployment failed." >&2
        exit 1
    fi

    echo "Helm deployment successful."
}

# Task 7.4: Wait for rollout completion
wait_for_rollout() {
    echo "Waiting for rollout to complete (timeout: ${ROLLOUT_TIMEOUT}s)..."

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] kubectl rollout status deployment/iskaar-backend -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}s"
        echo "[DRY-RUN] kubectl rollout status deployment/iskaar-frontend -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}s"
        return 0
    fi

    if ! kubectl rollout status deployment/iskaar-backend -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"; then
        echo "Error: Rollout did not complete within ${ROLLOUT_TIMEOUT}s." >&2
        exit 1
    fi

    if ! kubectl rollout status deployment/iskaar-frontend -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"; then
        echo "Error: Rollout did not complete within ${ROLLOUT_TIMEOUT}s." >&2
        exit 1
    fi

    echo "Rollout completed successfully."
}

# Task 7.4: Show deployment status
show_status() {
    echo "=== Deployment Status ==="

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] kubectl get pods -n ${NAMESPACE} -o wide"
        echo "[DRY-RUN] kubectl get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.status.phase}{\"\t\"}{.spec.containers[*].image}{\"\n\"}{end}'"
        return 0
    fi

    kubectl get pods -n "${NAMESPACE}" -o wide
    echo ""
    echo "Pod details:"
    kubectl get pods -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
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
            *)
                echo "Error: Unknown option '$1'" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# --- Main Orchestration ------------------------------------------------------

main() {
    parse_args "$@"

    echo "=== Iskaar Deploy ==="
    echo "Environment: $ENVIRONMENT"
    echo "Dry-run: $DRY_RUN"
    echo ""

    validate_prerequisites
    determine_tag
    check_registry
    build_images
    push_images
    deploy_to_cluster
    wait_for_rollout
    show_status

    echo ""
    echo "=== Deployment complete ==="
}

# --- Entry Point -------------------------------------------------------------
# NOTE: Make this script executable with: chmod +x deploy.sh

main "$@"
