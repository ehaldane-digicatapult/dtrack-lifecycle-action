#!/usr/bin/env bash
# Shared setup loaded by every dtrack-lifecycle.sh bats test file via:
#   load test_helper/common
#
# Provides:
#   - bats-support / bats-assert loaded and ready to use
#   - dtrack-lifecycle.sh sourced (functions available, main() not run)
#   - sane default env vars (DTRACK_URI, API_KEY, PROJECT_NAME, ...)
#   - mock_curl helpers, reset before every test

setup() {
    bats_load_library bats-support
    bats_load_library bats-assert

    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/test_helper/mock_curl.bash"
    mock_curl_reset

    export DTRACK_URI="https://dtrack.example.com"
    export API_KEY="test-api-key"
    export PROJECT_NAME="demo-service"
    export KEEP_N="1"
    export KEEP_ACTIVE=""

    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../src/dtrack-lifecycle.sh"

    # dtrack-lifecycle.sh sets -euo pipefail for its own top-level run;
    # relax that here so a failing assertion/function call inside a test
    # doesn't abort the whole bats test process. Individual functions are
    # invoked via `run`, which captures their exit status directly.
    set +euo pipefail
}

teardown() {
    [[ -n "${MOCK_CURL_DIR:-}" && -d "$MOCK_CURL_DIR" ]] && rm -rf "$MOCK_CURL_DIR"
}
