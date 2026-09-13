#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Readiness/deploy mode contract test
#
# This test uses local fixtures and an isolated command directory. It never
# needs a Docker daemon, Helm installation, Kubernetes cluster, Minikube
# profile, registry, or either sibling repository.
#
# Validates: Requirements 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.3, 3.4, 4.4, 6.1, 6.2, 6.3, 6.4, 6.6, 6.7, 9.4
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy.sh"
VALIDATOR_SCRIPT="${SCRIPT_DIR}/validate-readiness.sh"
ORIGINAL_PATH="${PATH}"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iskaar-deploy-mode.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
FIXTURE_ROOT="${TEST_ROOT}/fixtures"
BACKEND_CONTEXT="${FIXTURE_ROOT}/backend"
FRONTEND_CONTEXT="${FIXTURE_ROOT}/frontend"
SUCCESS_LOG="${TEST_ROOT}/success.trace"
FAILURE_LOG="${TEST_ROOT}/failure.trace"
SUCCESS_OUTPUT="${TEST_ROOT}/success.output"
FAILURE_OUTPUT="${TEST_ROOT}/failure.output"
SECURITY_LOG="${TEST_ROOT}/security.trace"
SECURITY_OUTPUT="${TEST_ROOT}/security.output"
MINIKUBE_SETUP_FIXTURE="${TEST_ROOT}/fake-minikube-setup.sh"
SECRET_FIXTURE_DIR="${DEPLOY_DIR}/secrets/.test-deploy-mode-${BASHPID}"
FAKE_TEMPLATE="${TEST_ROOT}/fake-command"

# These are deliberately synthetic test values. They are created only in the
# ignored temporary secrets/ subtree and are asserted never to be observable.
TEST_DB_VALUE="contract-db-4-3"
TEST_USER_VALUE="contract-user-4-3"
TEST_PASSWORD_VALUE="contract-password-4-3"

cleanup() {
    rm -rf -- "${TEST_ROOT}"
    rm -rf -- "${SECRET_FIXTURE_DIR}"
}
trap cleanup EXIT

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        Reason: $2"
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if grep -Fq -- "${pattern}" "${file}"; then
        pass "${description}"
    else
        fail_test "${description}" "Pattern '${pattern}' was not found in ${file}."
    fi
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if grep -Fq -- "${pattern}" "${file}"; then
        fail_test "${description}" "Unexpected pattern '${pattern}' was found in ${file}."
    else
        pass "${description}"
    fi
}

assert_non_empty_file() {
    local file="$1"
    local description="$2"

    if [[ -s "${file}" ]]; then
        pass "${description}"
    else
        fail_test "${description}" "Trace file is empty: ${file}."
    fi
}

create_fake_command() {
    local command_name="$1"
    cp -- "${FAKE_TEMPLATE}" "${FAKE_BIN}/${command_name}"
    chmod +x "${FAKE_BIN}/${command_name}"
}

create_fixtures() {
    mkdir -p -- "${FAKE_BIN}" "${BACKEND_CONTEXT}" "${FRONTEND_CONTEXT}"

    # Every fake writes a shell-escaped invocation to FAKE_COMMAND_LOG. The
    # fakes intentionally reject state-changing commands if they are called.
    cat > "${FAKE_TEMPLATE}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

command_name="$(basename -- "$0")"
command_name="${command_name%.exe}"
log_file="${FAKE_COMMAND_LOG:?FAKE_COMMAND_LOG must be set}"
{
    printf 'COMMAND %q' "${command_name}"
    for argument in "$@"; do
        printf ' %q' "${argument}"
    done
    printf '\n'
} >> "${log_file}"

first_argument="${1:-}"

case "${command_name}" in
    timeout)
        if [[ "$#" -lt 2 ]]; then
            exit 97
        fi
        shift
        exec "$@"
        ;;
    npm)
        if [[ "${FAKE_FAIL_NPM:-}" == "$*" ]]; then
            exit 42
        fi
        case "${first_argument}" in
            install|run|test)
                exit 0
                ;;
            *)
                exit 98
                ;;
        esac
        ;;
    docker)
        case "${first_argument}" in
            build)
                exit 0
                ;;
            image)
                case "${2:-}" in
                    inspect|ls)
                        exit 0
                        ;;
                    *)
                        exit 98
                        ;;
                esac
                ;;
            push)
                exit 96
                ;;
            *)
                exit 98
                ;;
        esac
        ;;
    helm)
        case "${first_argument}" in
            history)
                # Task 6.2: this isolated contract run represents a new
                # release, so Helm reports that no previous revision exists.
                printf '%s\n' 'Error: release: not found' >&2
                exit 1
                ;;
            lint)
                exit 0
                ;;
            template)
                printf '%s\n' \
                    'image: localhost:5000/iskaar-backend:contract-test' \
                    'image: localhost:5000/iskaar-frontend:contract-test'
                exit 0
                ;;
            upgrade|install|rollback)
                [[ "${FAKE_ALLOW_DEPLOY_MUTATIONS:-false}" == true ]] && exit 0
                exit 95
                ;;
            *)
                exit 98
                ;;
        esac
        ;;
    kubectl)
        client_render=false
        kubectl_verb=""
        for argument in "$@"; do
            if [[ "${argument}" == '--dry-run=client' ]]; then
                client_render=true
            fi
            case "${argument}" in
                apply|create|patch|delete|replace|rollout|scale|set|annotate|label|get|wait|describe)
                    if [[ -z "${kubectl_verb}" ]]; then
                        kubectl_verb="${argument}"
                    fi
                    ;;
            esac
        done

        case "${kubectl_verb}" in
            apply)
                if [[ "${client_render}" == true || "${FAKE_ALLOW_DEPLOY_MUTATIONS:-false}" == true ]]; then
                    exit 0
                fi
                exit 94
                ;;
            create|patch|delete|replace|rollout|scale|set|annotate|label)
                [[ "${FAKE_ALLOW_DEPLOY_MUTATIONS:-false}" == true ]] && exit 0
                exit 94
                ;;
            get|wait|describe)
                [[ "${FAKE_ALLOW_DEPLOY_MUTATIONS:-false}" == true ]] && exit 0
                exit 98
                ;;
            *)
                exit 98
                ;;
        esac
        ;;
    mvnw)
        exit 0
        ;;
    minikube)
        case "${first_argument}" in
            status)
                printf '%s\n' 'Running'
                exit 0
                ;;
            addons)
                printf '%s\n' 'registry enabled'
                exit 0
                ;;
            docker-env)
                # An empty output keeps the fake Docker daemon environment
                # local without evaluating host-specific exports.
                exit 0
                ;;
            *)
                exit 93
                ;;
        esac
        ;;
    git|curl|node|java)
        # These commands must not be executed in the readiness path. The
        # executable exists only so command discovery cannot use a host tool.
        exit 93
        ;;
    *)
        exit 92
        ;;
esac
EOF

    for command_name in docker helm kubectl minikube npm node java git timeout curl; do
        create_fake_command "${command_name}"
        cp -- "${FAKE_BIN}/${command_name}" "${FAKE_BIN}/${command_name}.exe"
        chmod +x "${FAKE_BIN}/${command_name}.exe"
    done

    # The validator invokes the Maven wrapper from the configured backend
    # context. It is a fixture, not the real backend build.
    cp -- "${FAKE_TEMPLATE}" "${BACKEND_CONTEXT}/mvnw"
    chmod +x "${BACKEND_CONTEXT}/mvnw"

    printf '%s\n' '<project />' > "${BACKEND_CONTEXT}/pom.xml"
    printf '%s\n' 'FROM scratch' > "${BACKEND_CONTEXT}/Dockerfile"
    printf '%s\n' '{}' > "${FRONTEND_CONTEXT}/package.json"
    printf '%s\n' '{"lockfileVersion": 3}' > "${FRONTEND_CONTEXT}/package-lock.json"
    printf '%s\n' 'FROM scratch' > "${FRONTEND_CONTEXT}/Dockerfile"

    # The setup helper is intentionally fake. Preflight cases must prove that
    # deploy=true stops before this executable, while the valid local-image
    # case may pass through it without contacting Minikube.
    cat > "${MINIKUBE_SETUP_FIXTURE}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

{
    printf 'COMMAND minikube-setup'
    for argument in "$@"; do
        printf ' %q' "${argument}"
    done
    printf '\n'
} >> "${FAKE_COMMAND_LOG:?FAKE_COMMAND_LOG must be set}"
EOF
    chmod +x "${MINIKUBE_SETUP_FIXTURE}"
}

create_secret_fixtures() {
    mkdir -p -- "${SECRET_FIXTURE_DIR}"

    # Missing file: no credential value is ever supplied to deploy.sh.
    MISSING_SECRET_FILE="${SECRET_FIXTURE_DIR}/missing.env"

    INCOMPLETE_SECRET_FILE="${SECRET_FIXTURE_DIR}/incomplete.env"
    {
        printf 'POSTGRES_DB=%s\n' "${TEST_DB_VALUE}"
        printf 'POSTGRES_USER=%s\n' "${TEST_USER_VALUE}"
    } > "${INCOMPLETE_SECRET_FILE}"

    PLACEHOLDER_SECRET_FILE="${SECRET_FIXTURE_DIR}/placeholder.env"
    {
        printf 'POSTGRES_DB=iskaar\n'
        printf 'POSTGRES_USER=%s\n' "${TEST_USER_VALUE}"
        printf 'POSTGRES_PASSWORD=%s\n' "${TEST_PASSWORD_VALUE}"
    } > "${PLACEHOLDER_SECRET_FILE}"

    COMPLETE_SECRET_FILE="${SECRET_FIXTURE_DIR}/complete.env"
    {
        printf 'POSTGRES_DB=%s\n' "${TEST_DB_VALUE}"
        printf 'POSTGRES_USER=%s\n' "${TEST_USER_VALUE}"
        printf 'POSTGRES_PASSWORD=%s\n' "${TEST_PASSWORD_VALUE}"
    } > "${COMPLETE_SECRET_FILE}"
}

configure_test_environment() {
    export PATH="${FAKE_BIN}:${ORIGINAL_PATH}"
    export FAKE_COMMAND_LOG="${SUCCESS_LOG}"
    export FAKE_FAIL_NPM=""

    # Use only local fixtures for application contexts. Existing repository
    # manifests and Helm chart files are read but never applied.
    export BACKEND_CONTEXT
    export FRONTEND_CONTEXT
    export HELM_CHART_PATH="${DEPLOY_DIR}/helm/iskaar"
    export K8S_PATH="${DEPLOY_DIR}/k8s"
    export MONITORING_PATH="${DEPLOY_DIR}/k8s/monitoring"
    export READINESS_VALIDATOR="${VALIDATOR_SCRIPT}"
    export REGISTRY="localhost:5000"
    export NAMESPACE="iskaar"
}

run_deploy_false() {
    local output_file="$1"

    if "${DEPLOY_SCRIPT}" dev \
        --deploy false \
        --monitoring false \
        --tag contract-test > "${output_file}" 2>&1; then
        return 0
    else
        local status=$?
        return "${status}"
    fi
}

assert_success_trace_is_non_mutating() {
    local trace_file="$1"
    local unexpected_trace

    assert_non_empty_file "${trace_file}" "Alle Fake-Aufrufe werden in einem Trace protokolliert"
    assert_file_contains "${trace_file}" 'COMMAND mvnw clean install -B' "Backend-Maven-Aufruf ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND npm install' "Frontend-Installationsschritt ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND npm run build' "Frontend-Build ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND npm test' "Frontend-Test ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND docker build' "Lokale Image-Builds sind im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND helm lint' "Helm-Lint ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND helm template' "Helm-Rendering ist im Trace enthalten"
    assert_file_contains "${trace_file}" 'COMMAND kubectl apply --dry-run=client' "Nur lokales kubectl-Client-Rendering ist im Trace enthalten"

    assert_file_not_contains "${trace_file}" 'COMMAND docker push' "Readiness führt keinen docker push aus"
    assert_file_not_contains "${trace_file}" 'COMMAND minikube' "Readiness fragt keinen Minikube-Status ab"
    assert_file_not_contains "${trace_file}" 'COMMAND helm upgrade' "Readiness erzeugt oder aktualisiert kein Helm-Release"
    assert_file_not_contains "${trace_file}" 'COMMAND helm install' "Readiness installiert kein Helm-Release"
    assert_file_not_contains "${trace_file}" 'COMMAND helm rollback' "Readiness führt keinen Helm-Rollback aus"
    assert_file_not_contains "${trace_file}" 'COMMAND kubectl create' "Readiness erzeugt keine Namespace-/Secret-/Ressource"
    assert_file_not_contains "${trace_file}" 'COMMAND kubectl patch' "Readiness patcht keine Kubernetes-Ressource"
    assert_file_not_contains "${trace_file}" 'COMMAND kubectl delete' "Readiness löscht keine Kubernetes-Ressource"

    unexpected_trace="$(grep -E '^COMMAND kubectl apply( |$)' "${trace_file}" | grep -v '^COMMAND kubectl apply --dry-run=client' || true)"
    if [[ -z "${unexpected_trace}" ]]; then
        pass "Jeder kubectl-apply-Aufruf bleibt auf --dry-run=client beschränkt"
    else
        fail_test "Jeder kubectl-apply-Aufruf bleibt auf --dry-run=client beschränkt" "${unexpected_trace}"
    fi
}

run_success_case() {
    echo "[Case 1] deploy=false erfolgreich und ohne Cluster-Mutation"
    : > "${SUCCESS_LOG}"
    export FAKE_COMMAND_LOG="${SUCCESS_LOG}"
    export FAKE_FAIL_NPM=""

    local exit_code=0
    if run_deploy_false "${SUCCESS_OUTPUT}"; then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ "${exit_code}" -eq 0 ]]; then
        pass "deploy=false endet erfolgreich mit Exit-Code 0"
    else
        fail_test "deploy=false endet erfolgreich mit Exit-Code 0" "Exit-Code ${exit_code}; siehe ${SUCCESS_OUTPUT}."
    fi

    assert_file_contains "${SUCCESS_OUTPUT}" 'Mode: READINESS (deploy=false)' "Readiness-Modus wird ausgegeben"
    assert_file_contains "${SUCCESS_OUTPUT}" 'Minikube target: not contacted' "Readiness meldet kein kontaktiertes Minikube-Ziel"
    assert_file_contains "${SUCCESS_OUTPUT}" 'Cluster mutations: none (readiness mode)' "Readiness bestätigt fehlende Cluster-Mutation"
    assert_success_trace_is_non_mutating "${SUCCESS_LOG}"
}

run_failure_case() {
    echo "[Case 2] Readiness-Fehler stoppt spätere Schritte"
    : > "${FAILURE_LOG}"
    export FAKE_COMMAND_LOG="${FAILURE_LOG}"
    export FAKE_FAIL_NPM='run build'

    local exit_code=0
    if run_deploy_false "${FAILURE_OUTPUT}"; then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ "${exit_code}" -ne 0 ]]; then
        pass "Ein fehlschlagender Readiness-Schritt liefert Exit-Code ungleich null"
    else
        fail_test "Ein fehlschlagender Readiness-Schritt liefert Exit-Code ungleich null" "Unerwarteter Exit-Code 0."
    fi

    assert_file_contains "${FAILURE_OUTPUT}" 'Frontend build' "Der betroffene Readiness-Schritt wird benannt"
    assert_file_contains "${FAILURE_OUTPUT}" 'Readiness phase failed' "Der Readiness-Fehler wird im Report benannt"
    assert_file_contains "${FAILURE_LOG}" 'COMMAND npm install' "Schritte bis zum Fehler werden protokolliert"
    assert_file_contains "${FAILURE_LOG}" 'COMMAND npm run build' "Der fehlschlagende Schritt wird protokolliert"
    assert_file_not_contains "${FAILURE_LOG}" 'COMMAND npm test' "Nach dem Fehler startet kein späterer Frontend-Test"
    assert_file_not_contains "${FAILURE_LOG}" 'COMMAND docker build' "Nach dem Fehler starten keine Image-Builds"
    assert_file_not_contains "${FAILURE_LOG}" 'COMMAND helm' "Nach dem Fehler startet kein Helm-Schritt"
    assert_file_not_contains "${FAILURE_LOG}" 'COMMAND kubectl' "Nach dem Fehler startet kein Kubernetes-Schritt"
    assert_file_not_contains "${FAILURE_LOG}" 'COMMAND minikube' "Nach dem Fehler startet kein Minikube-Schritt"
}

assert_trace_command_absent() {
    local trace_file="$1"
    local command_pattern="$2"
    local description="$3"

    if [[ -f "${trace_file}" ]] && grep -Fq -- "${command_pattern}" "${trace_file}"; then
        fail_test "${description}" "Unexpected fake command was executed: ${command_pattern}."
    else
        pass "${description}"
    fi
}

assert_secret_absent() {
    local file="$1"
    local secret_value="$2"
    local description="$3"

    if [[ -f "${file}" ]] && grep -Fq -- "${secret_value}" "${file}"; then
        # Never include the credential itself in a failure diagnostic.
        fail_test "${description}" "Credential material was found in ${file}."
    else
        pass "${description}"
    fi
}

assert_secret_absent_from_command_family() {
    local trace_file="$1"
    local command_prefix="$2"
    local secret_value="$3"
    local description="$4"
    local matching_lines=""

    if [[ -f "${trace_file}" ]]; then
        matching_lines="$(grep -F -- "${command_prefix}" "${trace_file}" 2>/dev/null | grep -F -- "${secret_value}" || true)"
    fi

    if [[ -n "${matching_lines}" ]]; then
        # Never echo matching command lines: they could contain the credential.
        fail_test "${description}" "Credential material was found in the selected command arguments."
    else
        pass "${description}"
    fi
}

assert_preflight_stops_before_mutation() {
    local output_file="$1"
    local trace_file="$2"
    local description_prefix="$3"

    assert_trace_command_absent "${trace_file}" 'COMMAND minikube-setup' "${description_prefix}: Minikube setup wird nicht gestartet"
    assert_trace_command_absent "${trace_file}" 'COMMAND minikube' "${description_prefix}: kein Minikube-Befehl wird ausgeführt"
    assert_trace_command_absent "${trace_file}" 'COMMAND docker' "${description_prefix}: kein Docker-Befehl wird ausgeführt"
    assert_trace_command_absent "${trace_file}" 'COMMAND kubectl' "${description_prefix}: Namespace-/Secret-Mutation wird nicht ausgeführt"
    assert_trace_command_absent "${trace_file}" 'COMMAND helm' "${description_prefix}: kein Helm-Schritt wird ausgeführt"
    assert_file_not_contains "${output_file}" '[DEPLOY] Starting local Minikube setup' "${description_prefix}: Setup-Phase wird nicht erreicht"
    assert_file_not_contains "${output_file}" 'Namespace phase' "${description_prefix}: Namespace-Phase wird nicht erreicht"
    assert_file_not_contains "${output_file}" 'Local secret phase' "${description_prefix}: Secret-Phase wird nicht erreicht"
    assert_file_not_contains "${output_file}" 'Deploying to cluster' "${description_prefix}: Helm-Deployment wird nicht erreicht"
}

run_deploy_true_case() {
    local output_file="$1"
    local trace_file="$2"
    local secret_file="$3"
    local registry="$4"
    local allow_mutations="$5"
    local partial_environment="${6:-false}"
    local -a credential_args=(-u KUBECONFIG)

    if [[ "${partial_environment}" == true ]]; then
        credential_args+=(-u POSTGRES_USER -u POSTGRES_PASSWORD "POSTGRES_DB=${TEST_DB_VALUE}")
    else
        credential_args+=(-u POSTGRES_DB -u POSTGRES_USER -u POSTGRES_PASSWORD)
    fi

    : > "${trace_file}"
    env \
        "${credential_args[@]}" \
        "PATH=${FAKE_BIN}:${ORIGINAL_PATH}" \
        "FAKE_COMMAND_LOG=${trace_file}" \
        "FAKE_ALLOW_DEPLOY_MUTATIONS=${allow_mutations}" \
        "MINIKUBE_SETUP_SCRIPT=${MINIKUBE_SETUP_FIXTURE}" \
        "POSTGRES_SECRET_FILE=${secret_file}" \
        "REGISTRY=${registry}" \
        "NAMESPACE=iskaar" \
        "MINIKUBE_PROFILE=minikube" \
        "MINIKUBE_CONTEXT=minikube" \
        "MINIKUBE_DRIVER=docker" \
        "ACCESS_MODE=auto" \
        "BACKEND_CONTEXT=${BACKEND_CONTEXT}" \
        "FRONTEND_CONTEXT=${FRONTEND_CONTEXT}" \
        "HELM_CHART_PATH=${DEPLOY_DIR}/helm/iskaar" \
        "${DEPLOY_SCRIPT}" dev \
        --deploy true \
        --monitoring false \
        --tag safe-image-tag \
        --skip-smoke > "${output_file}" 2>&1
}

assert_preflight_rejected() {
    local case_name="$1"
    local output_file="$2"
    local trace_file="$3"
    local expected_message="$4"
    local exit_code="$5"

    if [[ "${exit_code}" -ne 0 ]]; then
        pass "${case_name}: deploy=true endet vor Mutation mit Exit-Code ungleich null"
    else
        fail_test "${case_name}: deploy=true muss vor Mutation abbrechen" "Unerwarteter Exit-Code 0."
    fi
    assert_file_contains "${output_file}" "${expected_message}" "${case_name}: Preflight-Fehler wird konkret benannt"
    assert_preflight_stops_before_mutation "${output_file}" "${trace_file}" "${case_name}"
    assert_secret_absent "${output_file}" "${TEST_DB_VALUE}" "${case_name}: Datenbankwert erscheint nicht in der Ausgabe"
    assert_secret_absent "${output_file}" "${TEST_USER_VALUE}" "${case_name}: Benutzerwert erscheint nicht in der Ausgabe"
    assert_secret_absent "${output_file}" "${TEST_PASSWORD_VALUE}" "${case_name}: Passwort erscheint nicht in der Ausgabe"
    assert_secret_absent "${trace_file}" "${TEST_DB_VALUE}" "${case_name}: Datenbankwert erscheint nicht im Command-Trace"
    assert_secret_absent "${trace_file}" "${TEST_USER_VALUE}" "${case_name}: Benutzerwert erscheint nicht im Command-Trace"
    assert_secret_absent "${trace_file}" "${TEST_PASSWORD_VALUE}" "${case_name}: Passwort erscheint nicht im Command-Trace"
}

test_secret_preflight_security_cases() {
    echo "[Case 3] Secret- und Ziel-Preflight stoppt deploy=true vor jeder Mutation"
    local output_file trace_file exit_code

    output_file="${TEST_ROOT}/missing-secret.output"
    trace_file="${TEST_ROOT}/missing-secret.trace"
    if run_deploy_true_case "${output_file}" "${trace_file}" "${MISSING_SECRET_FILE}" 'localhost:5000' false; then
        exit_code=0
    else
        exit_code=$?
    fi
    assert_preflight_rejected "Fehlende Secret-Datei" "${output_file}" "${trace_file}" 'no usable local secret file' "${exit_code}"

    output_file="${TEST_ROOT}/partial-environment.output"
    trace_file="${TEST_ROOT}/partial-environment.trace"
    if run_deploy_true_case "${output_file}" "${trace_file}" "${MISSING_SECRET_FILE}" 'localhost:5000' false true; then
        exit_code=0
    else
        exit_code=$?
    fi
    assert_preflight_rejected "Fehlende Secret-Variable" "${output_file}" "${trace_file}" 'must be provided together' "${exit_code}"

    output_file="${TEST_ROOT}/incomplete-secret.output"
    trace_file="${TEST_ROOT}/incomplete-secret.trace"
    if run_deploy_true_case "${output_file}" "${trace_file}" "${INCOMPLETE_SECRET_FILE}" 'localhost:5000' false; then
        exit_code=0
    else
        exit_code=$?
    fi
    assert_preflight_rejected "Unvollständige lokale Secret-Datei" "${output_file}" "${trace_file}" 'local secret file is incomplete' "${exit_code}"

    output_file="${TEST_ROOT}/placeholder-secret.output"
    trace_file="${TEST_ROOT}/placeholder-secret.trace"
    if run_deploy_true_case "${output_file}" "${trace_file}" "${PLACEHOLDER_SECRET_FILE}" 'localhost:5000' false; then
        exit_code=0
    else
        exit_code=$?
    fi
    assert_preflight_rejected "Placeholder-Secret" "${output_file}" "${trace_file}" 'known placeholder value' "${exit_code}"

    output_file="${TEST_ROOT}/remote-registry.output"
    trace_file="${TEST_ROOT}/remote-registry.trace"
    if run_deploy_true_case "${output_file}" "${trace_file}" "${COMPLETE_SECRET_FILE}" 'registry.example.invalid:5000' false; then
        exit_code=0
    else
        exit_code=$?
    fi
    assert_preflight_rejected "Remote-Registry" "${output_file}" "${trace_file}" 'Remote registry' "${exit_code}"
}

test_valid_secret_and_image_security() {
    echo "[Case 4] Gültiges Local_Secret bleibt nicht beobachtbar und lokale Images werden nicht gepusht"
    local output_file="${SECURITY_OUTPUT}"
    local trace_file="${SECURITY_LOG}"
    local exit_code=0

    if run_deploy_true_case "${output_file}" "${trace_file}" "${COMPLETE_SECRET_FILE}" '' true; then
        exit_code=0
    else
        exit_code=$?
    fi

    if [[ "${exit_code}" -eq 0 ]]; then
        pass "Gültiges Local_Secret durchläuft den isolierten lokalen Image-/Helm-Pfad"
    else
        fail_test "Gültiges Local_Secret durchläuft den isolierten lokalen Image-/Helm-Pfad" "Exit-Code ${exit_code}; siehe ${output_file}."
    fi

    assert_file_contains "${output_file}" 'Image target: Minikube Docker daemon' "Leere Registry wählt den lokalen Minikube-Docker-Daemon"
    assert_file_contains "${trace_file}" 'COMMAND minikube-setup' "Der echte Deploy-Pfad wird ausschließlich über den Fake-Setup-Wrapper betreten"
    assert_file_contains "${trace_file}" 'COMMAND docker build' "Lokale Backend-/Frontend-Image-Builds werden vorbereitet"
    assert_file_contains "${trace_file}" 'COMMAND helm upgrade' "Helm-Argumente werden im isolierten Fake-Trace beobachtet"
    assert_file_contains "${trace_file}" 'postgresql.existingSecret=postgres-credentials' "Helm erhält nur den festen Secret-Namen"
    assert_file_contains "${trace_file}" 'iskaar-backend:safe-image-tag' "Backend-Image-Tag bleibt frei von Secretwerten"
    assert_file_contains "${trace_file}" 'iskaar-frontend:safe-image-tag' "Frontend-Image-Tag bleibt frei von Secretwerten"
    assert_file_not_contains "${trace_file}" 'COMMAND docker push' "Lokale Image-Bereitstellung führt keinen docker push aus"

    assert_secret_absent "${output_file}" "${TEST_DB_VALUE}" "Secret-Datenbankwert erscheint nicht in der Ausgabe"
    assert_secret_absent "${output_file}" "${TEST_USER_VALUE}" "Secret-Benutzerwert erscheint nicht in der Ausgabe"
    assert_secret_absent "${output_file}" "${TEST_PASSWORD_VALUE}" "Secret-Passwort erscheint nicht in der Ausgabe"
    assert_secret_absent "${trace_file}" "${TEST_DB_VALUE}" "Secret-Datenbankwert erscheint nicht im Command-Trace"
    assert_secret_absent "${trace_file}" "${TEST_USER_VALUE}" "Secret-Benutzerwert erscheint nicht im Command-Trace"
    assert_secret_absent "${trace_file}" "${TEST_PASSWORD_VALUE}" "Secret-Passwort erscheint nicht im Command-Trace"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND helm' "${TEST_DB_VALUE}" "Datenbankwert erscheint nicht in Helm-Argumenten"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND helm' "${TEST_USER_VALUE}" "Benutzerwert erscheint nicht in Helm-Argumenten"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND helm' "${TEST_PASSWORD_VALUE}" "Passwort erscheint nicht in Helm-Argumenten"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND docker' "${TEST_DB_VALUE}" "Datenbankwert erscheint nicht in Image-Argumenten"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND docker' "${TEST_USER_VALUE}" "Benutzerwert erscheint nicht in Image-Argumenten"
    assert_secret_absent_from_command_family "${trace_file}" 'COMMAND docker' "${TEST_PASSWORD_VALUE}" "Passwort erscheint nicht in Image-Argumenten"
}

create_fixtures
create_secret_fixtures
configure_test_environment

cat <<EOF
=============================================
  Deploy Mode Contract Test
=============================================
Deploy script: ${DEPLOY_SCRIPT}
Validator:     ${VALIDATOR_SCRIPT}
Fake PATH:     ${FAKE_BIN}

External prerequisites intentionally skipped:
  - Docker daemon and registry
  - Helm binary and Kubernetes cluster
  - Minikube profile, tunnel, and addons (fake setup helper is used for deploy=true)
  - Real backend/frontend sibling builds
  - Real credentials (synthetic values are temporary and never printed)

EOF

run_success_case
echo ""
run_failure_case
echo ""
test_secret_preflight_security_cases
echo ""
test_valid_secret_and_image_security

echo ""
echo "============================================="
echo "  Trace / Assertion Summary"
echo "============================================="
echo "  Run:     ${TESTS_RUN}"
echo "  Passed:  ${TESTS_PASSED}"
echo "  Failed:  ${TESTS_FAILED}"
echo "  Traces:  ${SUCCESS_LOG}, ${FAILURE_LOG} (temporary)"
echo "============================================="

if [[ "${TESTS_FAILED}" -gt 0 ]]; then
    echo "  RESULT: FAILED"
    exit 1
fi

echo "  RESULT: ALL PASSED"
