#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Iskaar Smoke Tests
# Verifies basic service health after deployment.
# Usage: ./smoke-test.sh <environment> [--backend-url <url>] [--frontend-url <url>]
# =============================================================================

# --- Configuration -----------------------------------------------------------

ENVIRONMENT="${1:-dev}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"
TIMEOUT="${TIMEOUT:-60}"
BACKEND_URL=""
FRONTEND_URL=""

# --- Argument Parsing --------------------------------------------------------

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "Error: Environment argument is required." >&2
        usage
        exit 1
    fi

    for arg in "$@"; do
        if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    ENVIRONMENT="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend-url)
                BACKEND_URL="$2"
                shift 2
                ;;
            --frontend-url)
                FRONTEND_URL="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$ENVIRONMENT" in
        dev|stage|prod) ;;
        *)
            echo "Error: Invalid environment '$ENVIRONMENT'. Must be dev, stage, or prod." >&2
            exit 1
            ;;
    esac

    resolve_urls
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <environment> [options]

Run smoke tests against a deployed Iskaar environment.

Arguments:
  environment          Target environment: dev, stage, or prod

Options:
  --backend-url <url>  Override backend base URL
  --frontend-url <url> Override frontend base URL
  -h, --help           Show this help message

Environment defaults:
  dev:   backend=https://iskaar.games  frontend=https://iskaar.games
  stage: backend=https://iskaar.games  frontend=https://iskaar.games
  prod:  backend=https://iskaar.games  frontend=https://iskaar.games

Environment variables:
  MAX_RETRIES    Number of retry attempts per check (default: 3)
  RETRY_DELAY    Seconds between retries (default: 10)
  TIMEOUT        Curl timeout in seconds per request (default: 60)

Examples:
  $(basename "$0") dev
  $(basename "$0") dev --backend-url http://localhost:8080 --frontend-url http://localhost:4173
  $(basename "$0") prod --backend-url https://iskaar.games
EOF
}

resolve_urls() {
    if [[ -z "$BACKEND_URL" ]]; then
        case "$ENVIRONMENT" in
            dev)   BACKEND_URL="https://iskaar.games" ;;
            stage) BACKEND_URL="https://iskaar.games" ;;
            prod)  BACKEND_URL="https://iskaar.games" ;;
        esac
    fi

    if [[ -z "$FRONTEND_URL" ]]; then
        case "$ENVIRONMENT" in
            dev)   FRONTEND_URL="https://iskaar.games" ;;
            stage) FRONTEND_URL="https://iskaar.games" ;;
            prod)  FRONTEND_URL="https://iskaar.games" ;;
        esac
    fi
}

# --- Core Functions ----------------------------------------------------------

check_endpoint() {
    local url="$1"
    local expected_status="$2"
    local description="$3"

    for i in $(seq 1 "$MAX_RETRIES"); do
        local status
        status=$(curl -sk -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$url" 2>/dev/null || echo "000")

        if [[ "$status" == "$expected_status" ]]; then
            echo "  ✅ $description — HTTP $status"
            return 0
        fi

        if [[ "$i" -lt "$MAX_RETRIES" ]]; then
            echo "  ⏳ $description — Got HTTP $status, expected $expected_status (attempt $i/$MAX_RETRIES)"
            sleep "$RETRY_DELAY"
        fi
    done

    echo "  ❌ $description — FAILED (last status: $status, expected: $expected_status)"
    return 1
}

# --- Main --------------------------------------------------------------------

main() {
    parse_args "$@"

    echo "=== Iskaar Smoke Tests ==="
    echo "Environment: $ENVIRONMENT"
    echo "Backend URL: $BACKEND_URL"
    echo "Frontend URL: $FRONTEND_URL"
    echo "Retries: $MAX_RETRIES, Delay: ${RETRY_DELAY}s, Timeout: ${TIMEOUT}s"
    echo ""

    local failures=0

    echo "Checks:"
    check_endpoint "${BACKEND_URL}/actuator/health" "200" "Backend Health (/actuator/health)" || ((failures+=1)) || true
    check_endpoint "${FRONTEND_URL}/" "200" "Frontend Index (/)" || ((failures+=1)) || true
    check_endpoint "${BACKEND_URL}/ws" "400" "WebSocket Endpoint (/ws — no upgrade)" || ((failures+=1)) || true

    echo ""
    if [[ $failures -gt 0 ]]; then
        echo "❌ $failures of 3 smoke test(s) failed!"
        exit 1
    else
        echo "✅ All smoke tests passed!"
        exit 0
    fi
}

main "$@"
